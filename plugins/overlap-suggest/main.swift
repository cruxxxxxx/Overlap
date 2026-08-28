import Foundation
import Vision
import Accelerate

// Overlap "Overlap Suggest" plugin — the unified multi-signal suggester.
//
// Phase 1 (this file): merges visionknn (FeaturePrint kNN over the user's tagged
// corpus) and facecluster (persistent face-identity clusters) into ONE plugin with
// ONE cache: one image decode feeds every Vision request, one meta.json records
// per-image signal state, and two mmap'd blobs hold the vectors. Existing caches
// from both old plugins are migrated in place — no re-embedding.
//
// Signal model: each image record stores per-signal fields (fpRow, faces, …).
// A nil field means "not yet computed" — that is the incremental/backfill
// mechanism. Changing the file (sig mismatch) recomputes everything.
//
// Later phases add: co-occurrence rerank + mutex, VNClassifyImageRequest labels,
// OCR, face-quality gating, aesthetics, config.json tunables.
//
// The contract IS the JSON — structs mirror Sources/PluginContract.swift.

// MARK: - Wire contract

struct RequestFile: Codable {
    let path: String; let kind: String
    let ext: String; let tags: [String]
    let size: Int64?; let modDate: Date?; let createdDate: Date?
}
struct LibraryItem: Codable {
    let path: String; let kind: String
    let tags: [String]; let modDate: Date?
}
struct SuggestRequest: Codable {
    let protocolVersion: Int?
    let files: [RequestFile]
    let knownTags: [String]?
    let library: [LibraryItem]?
}
struct RawSuggestion: Codable {
    let path: String; let tag: String
    let confidence: Double; let source: String?
    var group: Bool? = nil
}
struct SuggestResponse: Codable {
    let protocolVersion: Int
    let suggestions: [RawSuggestion]
}

// MARK: - Tunables (config.json arrives in phase 2)

let K = 7                       // kNN neighbors
let MIN_CONFIDENCE = 0.30
let MAX_TAGS_PER_FILE = 6
let JOIN_THRESHOLD: Float = 0.84
let NAME_MIN_SHARE = 0.5
let NAME_MIN_CONCENTRATION = 0.6
let W_KNN = 1.0                 // noisy-OR channel weights
let W_FACE = 1.0
let SOURCE = "overlap-suggest"

// MARK: - Vision helpers

func normalize(_ v: inout [Float]) {
    var n: Float = 0
    vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = n.squareRoot()
    if n > 0 { var inv = 1 / n; vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count)) }
}

/// FeaturePrint vector from a performed request, or nil.
func fpVector(_ request: VNGenerateImageFeaturePrintRequest) -> [Float]? {
    guard let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }
    let count = obs.elementCount
    var vec = [Float](repeating: 0, count: count)
    obs.data.withUnsafeBytes { raw in
        let src = raw.bindMemory(to: Float.self)
        for i in 0..<min(count, src.count) { vec[i] = src[i] }
    }
    normalize(&vec)
    return vec
}

/// Faceprint vectors from a performed private request's results, or [].
func faceVectors(_ request: VNRequest) -> [[Float]] {
    guard let faces = request.results as? [VNFaceObservation] else { return [] }
    var out: [[Float]] = []
    for obs in faces {
        guard let fp = obs.value(forKey: "faceprint") as? NSObject,
              let count = fp.value(forKey: "elementCount") as? Int,
              let data = fp.value(forKey: "descriptorData") as? Data,
              count > 0, data.count >= count * 4 else { continue }
        var vec = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            for i in 0..<min(count, src.count) { vec[i] = src[i] }
        }
        normalize(&vec)
        out.append(vec)
    }
    return out
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var d: Float = 0
    a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
        vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &d, vDSP_Length(a.count)) } }
    return d
}

/// mtime fingerprint; host-supplied modDate avoids a stat on the hot path.
func signature(path: String, modDate: Date?) -> String {
    if let m = modDate { return "m:\(Int(m.timeIntervalSince1970))" }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
        .flatMap { $0 }?.timeIntervalSince1970 ?? -1
    return "s:\(Int(mtime))"
}

// MARK: - Persistent state

struct FaceRef: Codable { var row: Int; var cluster: Int; var quality: Float? }
struct LabelRef: Codable { var i: Int; var c: Float }   // interned classifier label (phase 3)
struct ImageRec: Codable {
    var sig: String
    var tags: [String]
    var fpRow: Int?          // nil = FeaturePrint not yet computed
    var faces: [FaceRef]?    // nil = face pass not yet run
    var labels: [LabelRef]?  // phase 3
    var ocr: [Int]?          // phase 3
}
struct ClusterState: Codable { var sum: [Float]; var count: Int }
struct Meta: Codable {
    var schemaVersion: Int = 2
    var fpDim: Int = 0
    var fpRows: Int = 0
    var faceDim: Int = 0
    var faceRows: Int = 0
    var images: [String: ImageRec] = [:]
    var labelVocab: [String] = []
    var tokenVocab: [String] = []
    var clusters: [Int: ClusterState] = [:]
    var nextCluster: Int = 1
}

let cacheRoot: URL = {
    if let override = ProcessInfo.processInfo.environment["OVERLAP_PLUGIN_CACHE"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Overlap/PluginCache", isDirectory: true)
}()
let cacheDir: URL = {
    let d = cacheRoot.appendingPathComponent("overlap-suggest", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()
let metaURL = cacheDir.appendingPathComponent("meta.json")
let fpBinURL = cacheDir.appendingPathComponent("featureprint.bin")
let faceBinURL = cacheDir.appendingPathComponent("faces.bin")

func stderrLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Migration from visionknn + facecluster caches (no re-embedding)

struct VKEntry: Codable { var row: Int; var sig: String; var tags: [String] }
struct VKMeta: Codable { var dim: Int; var entries: [String: VKEntry] }
struct FCFaceRef: Codable { var row: Int; var cluster: Int }
struct FCEntry: Codable { var sig: String; var faces: [FCFaceRef]; var tags: [String] }
struct FCMeta: Codable {
    var dim: Int; var rows: Int; var images: [String: FCEntry]
    var clusters: [Int: ClusterState]; var nextCluster: Int
}

func migrateIfNeeded() -> Meta {
    if let d = try? Data(contentsOf: metaURL),
       let m = try? JSONDecoder().decode(Meta.self, from: d) { return m }

    var m = Meta()
    let fm = FileManager.default
    var fromVK = 0, fromFC = 0

    // visionknn: index.bin + meta.json {dim, entries{path:{row,sig,tags}}}
    let vkDir = cacheRoot.appendingPathComponent("visionknn")
    if let d = try? Data(contentsOf: vkDir.appendingPathComponent("meta.json")),
       let vk = try? JSONDecoder().decode(VKMeta.self, from: d),
       fm.fileExists(atPath: vkDir.appendingPathComponent("index.bin").path) {
        try? fm.copyItem(at: vkDir.appendingPathComponent("index.bin"), to: fpBinURL)
        m.fpDim = vk.dim
        for (path, e) in vk.entries {
            m.images[path] = ImageRec(sig: e.sig, tags: e.tags, fpRow: e.row,
                                      faces: nil, labels: nil, ocr: nil)
            m.fpRows = max(m.fpRows, e.row + 1)
        }
        fromVK = vk.entries.count
    }

    // facecluster: faces.bin + meta.json {dim, rows, images{path:{sig,faces,tags}}, clusters}
    let fcDir = cacheRoot.appendingPathComponent("facecluster")
    if let d = try? Data(contentsOf: fcDir.appendingPathComponent("meta.json")),
       let fc = try? JSONDecoder().decode(FCMeta.self, from: d),
       fm.fileExists(atPath: fcDir.appendingPathComponent("faces.bin").path) {
        try? fm.copyItem(at: fcDir.appendingPathComponent("faces.bin"), to: faceBinURL)
        m.faceDim = fc.dim
        m.faceRows = fc.rows
        m.clusters = fc.clusters
        m.nextCluster = fc.nextCluster
        for (path, e) in fc.images {
            let refs = e.faces.map { FaceRef(row: $0.row, cluster: $0.cluster, quality: nil) }
            if var rec = m.images[path] {
                if rec.sig == e.sig {
                    rec.faces = refs
                    if rec.tags.isEmpty { rec.tags = e.tags }
                    m.images[path] = rec
                }
                // sig mismatch: keep the fp side; faces stay nil → backfilled later
            } else {
                m.images[path] = ImageRec(sig: e.sig, tags: e.tags, fpRow: nil,
                                          faces: refs, labels: nil, ocr: nil)
            }
        }
        fromFC = fc.images.count
    }

    if fromVK + fromFC > 0 {
        stderrLine("overlap-suggest: migrated \(fromVK) visionknn + \(fromFC) facecluster records")
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: metaURL) }
    }
    return m
}

var meta = migrateIfNeeded()
func saveMeta() { if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL) } }

func centroid(_ c: ClusterState) -> [Float] {
    var v = c.sum; normalize(&v); return v
}

/// Assign a face vector to the nearest cluster (or a new one), updating centroids.
func assignCluster(_ vec: [Float]) -> Int {
    var best = -1
    var bestSim = JOIN_THRESHOLD
    for (id, c) in meta.clusters {
        let s = cosine(vec, centroid(c))
        if s >= bestSim { bestSim = s; best = id }
    }
    if best == -1 {
        best = meta.nextCluster; meta.nextCluster += 1
        meta.clusters[best] = ClusterState(sum: vec, count: 1)
    } else {
        var c = meta.clusters[best]!
        for i in 0..<c.sum.count { c.sum[i] += vec[i] }
        c.count += 1
        meta.clusters[best] = c
    }
    return best
}

// MARK: - Index sync (one decode per image; per-signal backfill)

let faceprintClass = NSClassFromString("VNCreateFaceprintRequest") as? NSObject.Type

func syncIndex(items: [(path: String, modDate: Date?, tags: [String])],
               progress: (Int, Int) -> Void) {
    for url in [fpBinURL, faceBinURL] where !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let fpFH = try? FileHandle(forUpdating: fpBinURL),
          let faceFH = try? FileHandle(forUpdating: faceBinURL) else { return }
    defer { try? fpFH.close(); try? faceFH.close() }
    _ = try? fpFH.seekToEnd(); _ = try? faceFH.seekToEnd()

    // Work = sig changed (everything) or an enabled signal is missing (backfill).
    func needsWork(_ rec: ImageRec?, _ sig: String) -> Bool {
        guard let rec, rec.sig == sig else { return true }
        return rec.fpRow == nil || (rec.faces == nil && faceprintClass != nil)
    }
    let todo = items.filter { needsWork(meta.images[$0.path], signature(path: $0.path, modDate: $0.modDate)) }
    var done = 0

    for it in items {
        let sig = signature(path: it.path, modDate: it.modDate)
        let existing = meta.images[it.path]
        if let e = existing, e.sig == sig, !needsWork(e, sig) {
            if e.tags != it.tags { meta.images[it.path]?.tags = it.tags }
            continue
        }
        let sigChanged = existing?.sig != sig
        var rec = (sigChanged || existing == nil)
            ? ImageRec(sig: sig, tags: it.tags, fpRow: nil, faces: nil, labels: nil, ocr: nil)
            : existing!
        rec.sig = sig
        rec.tags = it.tags

        // Build the request list for exactly the missing signals — one decode.
        var requests: [VNRequest] = []
        var fpReq: VNGenerateImageFeaturePrintRequest?
        var faceReq: VNRequest?
        if rec.fpRow == nil {
            let r = VNGenerateImageFeaturePrintRequest(); fpReq = r; requests.append(r)
        }
        if rec.faces == nil, let cls = faceprintClass, let r = cls.init() as? VNRequest {
            faceReq = r; requests.append(r)
        }
        if !requests.isEmpty {
            let handler = VNImageRequestHandler(url: URL(fileURLWithPath: it.path), options: [:])
            do {
                try handler.perform(requests)
            } catch {
                // Batch failed (unreadable file or one bad request): retry singly so
                // one signal can't sink the others.
                for r in requests { try? handler.perform([r]) }
            }
            if let fpReq {
                if let vec = fpVector(fpReq) {
                    if meta.fpDim == 0 { meta.fpDim = vec.count }
                    if vec.count == meta.fpDim {
                        try? fpFH.seek(toOffset: UInt64(meta.fpRows * meta.fpDim * 4))
                        fpFH.write(vec.withUnsafeBytes { Data($0) })
                        rec.fpRow = meta.fpRows
                        meta.fpRows += 1
                    }
                } else {
                    rec.fpRow = -1   // unreadable: present-but-empty, don't retry forever
                }
            }
            if let faceReq {
                let vecs = faceVectors(faceReq)
                if meta.faceDim == 0, let f = vecs.first { meta.faceDim = f.count }
                var refs: [FaceRef] = []
                for v in vecs where v.count == meta.faceDim {
                    try? faceFH.seek(toOffset: UInt64(meta.faceRows * meta.faceDim * 4))
                    faceFH.write(v.withUnsafeBytes { Data($0) })
                    refs.append(FaceRef(row: meta.faceRows, cluster: assignCluster(v), quality: nil))
                    meta.faceRows += 1
                }
                rec.faces = refs
            }
        }
        meta.images[it.path] = rec
        done += 1
        if done % 25 == 0 { saveMeta(); progress(done, todo.count) }
    }
    if done > 0 { saveMeta() }
}

// MARK: - Cluster naming (learned from the user's tags)

func clusterNames() -> [Int: String] {
    var globalTagCount: [String: Int] = [:]
    var clusterTagCount: [Int: [String: Int]] = [:]
    var clusterSize: [Int: Int] = [:]
    for (_, rec) in meta.images {
        let clustersHere = Set((rec.faces ?? []).map { $0.cluster }.filter { $0 >= 0 })
        for c in clustersHere { clusterSize[c, default: 0] += 1 }
        for tag in Set(rec.tags) {
            globalTagCount[tag, default: 0] += 1
            for c in clustersHere { clusterTagCount[c, default: [:]][tag, default: 0] += 1 }
        }
    }
    var names: [Int: String] = [:]
    for (c, size) in clusterSize {
        var bestTag: String? = nil
        var bestScore = 0
        for (tag, inC) in clusterTagCount[c] ?? [:] {
            let share = Double(inC) / Double(max(1, size))
            let concentration = Double(inC) / Double(max(1, globalTagCount[tag] ?? 1))
            if share >= NAME_MIN_SHARE, concentration >= NAME_MIN_CONCENTRATION, inC > bestScore {
                bestScore = inC; bestTag = tag
            }
        }
        names[c] = bestTag ?? "Person \(c)"
    }
    return names
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    stderrLine("overlap-suggest: bad request JSON")
    exit(1)
}

// Dedupe library + targets by path, union tags (a stale target copy must never
// clobber the library's authoritative tags).
var modByPath: [String: Date?] = [:]
var tagsByPath: [String: Set<String>] = [:]
for it in (req.library ?? []) { modByPath[it.path] = it.modDate; tagsByPath[it.path, default: []].formUnion(it.tags) }
for f in req.files { modByPath[f.path] = f.modDate; tagsByPath[f.path, default: []].formUnion(f.tags) }
let need = tagsByPath.map { (path: $0.key, modDate: modByPath[$0.key] ?? nil, tags: Array($0.value)) }
syncIndex(items: need) { done, total in
    stderrLine("Indexing… \(done)/\(total) new")
}

// ---- Query: channel A (kNN over FeaturePrint) + channel B (persons), noisy-OR.

var out: [RawSuggestion] = []
let names = clusterNames()

// mmap both blobs.
func mapBlob(_ url: URL) -> (ptr: UnsafeMutableRawPointer, size: Int)? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    let size = Int(lseek(fh.fileDescriptor, 0, SEEK_END))
    guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fh.fileDescriptor, 0),
          raw != MAP_FAILED else { return nil }
    return (raw, size)
}
let fpBlob = mapBlob(fpBinURL)
let faceBlob = mapBlob(faceBinURL)
defer {
    if let b = fpBlob { munmap(b.ptr, b.size) }
    if let b = faceBlob { munmap(b.ptr, b.size) }
}

// kNN reference rows: every tagged image with a valid fp row.
var refs: [(row: Int, tags: [String])] = []
if meta.fpDim > 0 {
    for (_, rec) in meta.images {
        if let r = rec.fpRow, r >= 0, !rec.tags.isEmpty { refs.append((r, rec.tags)) }
    }
}

for file in req.files {
    guard let rec = meta.images[file.path] else { continue }
    let own = Set(file.tags)
    var channelScores: [String: [Double]] = [:]   // tag -> per-channel weighted scores

    // Channel A — kNN borrowed tags.
    if let blob = fpBlob, let tRow = rec.fpRow, tRow >= 0, meta.fpDim > 0,
       (tRow + 1) * meta.fpDim * 4 <= blob.size {
        let base = blob.ptr.assumingMemoryBound(to: Float.self)
        let dim = meta.fpDim
        func rowPtr(_ r: Int) -> UnsafePointer<Float> { UnsafePointer(base).advanced(by: r * dim) }
        let tv = rowPtr(tRow)
        var scored: [(sim: Float, tags: [String])] = []
        scored.reserveCapacity(refs.count)
        for ref in refs where ref.row != tRow && (ref.row + 1) * dim * 4 <= blob.size {
            var d: Float = 0
            vDSP_dotpr(tv, 1, rowPtr(ref.row), 1, &d, vDSP_Length(dim))
            scored.append((d, ref.tags))
        }
        let top = scored.sorted { $0.sim > $1.sim }.prefix(K)
        let total = top.reduce(0.0) { $0 + max(0, Double($1.sim)) }
        if total > 0 {
            var weight: [String: Double] = [:]
            for n in top {
                for tag in Set(n.tags) where !own.contains(tag) {
                    weight[tag, default: 0] += max(0, Double(n.sim))
                }
            }
            for (tag, w) in weight {
                channelScores[tag, default: []].append(W_KNN * min(1, w / total))
            }
        }
    }

    // Channel B — persons (cluster names; confidence = face·centroid cosine).
    if let blob = faceBlob, meta.faceDim > 0 {
        let base = blob.ptr.assumingMemoryBound(to: Float.self)
        let dim = meta.faceDim
        var seen = Set<String>()
        for face in rec.faces ?? [] where face.cluster >= 0 {
            guard let name = names[face.cluster], !own.contains(name), !seen.contains(name),
                  (face.row + 1) * dim * 4 <= blob.size,
                  let cluster = meta.clusters[face.cluster] else { continue }
            seen.insert(name)
            let cent = centroid(cluster)
            var d: Float = 0
            cent.withUnsafeBufferPointer { pc in
                vDSP_dotpr(UnsafePointer(base).advanced(by: face.row * dim), 1,
                           pc.baseAddress!, 1, &d, vDSP_Length(dim))
            }
            let conf = max(0, min(1, Double(d)))
            channelScores[name, default: []].append(W_FACE * conf)
        }
    }

    // Noisy-OR fusion, threshold, cap. (Cooc rerank + mutex arrive in phase 2.)
    var fused = channelScores.map { (tag: $0.key,
                                     score: 1 - $0.value.reduce(1.0) { $0 * (1 - min(1, $1)) }) }
        .filter { $0.score >= MIN_CONFIDENCE }
        .sorted { $0.score > $1.score }
    fused = Array(fused.prefix(MAX_TAGS_PER_FILE))
    for f in fused {
        out.append(RawSuggestion(path: file.path, tag: f.tag,
                                 confidence: min(1, f.score), source: SOURCE))
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
