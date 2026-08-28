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

// MARK: - Config (config.json in the cache dir; defaults written on first run)

struct Config: Codable {
    var k = 7                        // kNN neighbors
    var minConfidence = 0.30
    var maxTagsPerFile = 6
    var highPrecisionMode = false    // true -> threshold 0.60 (research: P=.937/R=.616)
    var lambda = 0.2                 // cooc rerank strength (research: +3pts precision)
    var mutexFloor = 0.02            // pair "never co-occurs" ceiling for mutex-drop
    var minSupport = 5               // corpus uses a tag must have to join cooc/mutex
    var joinThreshold: Float = 0.84  // face-cluster join cosine
    var nameMinShare = 0.5           // cluster-name learning: share of cluster
    var nameMinConcentration = 0.6   //   ... and of the tag's global use
    var labelEnsembleAlpha = 0.3     // kNN sim = (1-α)·FeaturePrint + α·classifier-labels
    var faceQualityMin: Float = 0.2  // faces below this quality don't join clusters
    var clsMapMinP = 0.5             // learned P(userTag|label) acceptance
    var clsMapMinSupport = 8         //   ... and images-with-label support
    var coldStartMinTagged = 20      // corpus below this -> cold-start mode
    var weights = Weights()
    var signals = Signals()
    struct Weights: Codable {
        var knn = 1.0; var face = 1.0; var cls = 0.65; var ocr = 0.95
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            knn = try c.decodeIfPresent(Double.self, forKey: .knn) ?? 1.0
            face = try c.decodeIfPresent(Double.self, forKey: .face) ?? 1.0
            cls = try c.decodeIfPresent(Double.self, forKey: .cls) ?? 0.65
            ocr = try c.decodeIfPresent(Double.self, forKey: .ocr) ?? 0.95
        }
    }
    struct Signals: Codable {
        var classify = true; var ocr = true; var faces = true; var aesthetics = true
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            classify = try c.decodeIfPresent(Bool.self, forKey: .classify) ?? true
            ocr = try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? true
            faces = try c.decodeIfPresent(Bool.self, forKey: .faces) ?? true
            aesthetics = try c.decodeIfPresent(Bool.self, forKey: .aesthetics) ?? true
        }
    }

    init() {}
    // Tolerant decode: a config.json from an older version keeps working — missing
    // keys fall back to defaults instead of resetting the whole file.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func f<T: Decodable>(_ k: CodingKeys, _ def: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def
        }
        k = f(.k, 7); minConfidence = f(.minConfidence, 0.30)
        maxTagsPerFile = f(.maxTagsPerFile, 6); highPrecisionMode = f(.highPrecisionMode, false)
        lambda = f(.lambda, 0.2); mutexFloor = f(.mutexFloor, 0.02); minSupport = f(.minSupport, 5)
        joinThreshold = f(.joinThreshold, 0.84); nameMinShare = f(.nameMinShare, 0.5)
        nameMinConcentration = f(.nameMinConcentration, 0.6)
        labelEnsembleAlpha = f(.labelEnsembleAlpha, 0.3); faceQualityMin = f(.faceQualityMin, 0.2)
        clsMapMinP = f(.clsMapMinP, 0.5); clsMapMinSupport = f(.clsMapMinSupport, 8)
        coldStartMinTagged = f(.coldStartMinTagged, 20)
        weights = f(.weights, Weights()); signals = f(.signals, Signals())
    }
}
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

/// Faceprint vectors (+bboxes for quality matching) from a performed private
/// request's results, or [].
func faceVectors(_ request: VNRequest) -> [(vec: [Float], bbox: CGRect)] {
    guard let faces = request.results as? [VNFaceObservation] else { return [] }
    var out: [(vec: [Float], bbox: CGRect)] = []
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
        out.append((vec, obs.boundingBox))
    }
    return out
}

func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let ia = inter.width * inter.height
    let ua = a.width * a.height + b.width * b.height - ia
    return ua > 0 ? ia / ua : 0
}

/// Tokenize OCR output: lowercase words, length >= 3, deduped.
func ocrTokens(_ request: VNRecognizeTextRequest) -> [String] {
    guard let results = request.results else { return [] }
    var tokens = Set<String>()
    for obs in results {
        guard let text = obs.topCandidates(1).first?.string else { continue }
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if word.count >= 3 { tokens.insert(String(word)) }
        }
    }
    return Array(tokens)
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
struct LabelRef: Codable { var i: Int; var c: Float }   // interned classifier label
struct AesRef: Codable { var score: Float; var utility: Bool }
struct ImageRec: Codable {
    var sig: String
    var tags: [String]
    var fpRow: Int?          // nil = FeaturePrint not yet computed
    var faces: [FaceRef]?    // nil = face pass not yet run (cluster -1 = quality-gated)
    var labels: [LabelRef]?  // nil = classifier not yet run (interned via labelVocab)
    var ocr: [Int]?          // nil = OCR not yet run (interned via tokenVocab)
    var aes: AesRef?         // nil = aesthetics not run / OS too old
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
let configURL = cacheDir.appendingPathComponent("config.json")

let config: Config = {
    if let d = try? Data(contentsOf: configURL),
       let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    let c = Config()
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: configURL) }
    return c
}()

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
    var bestSim = config.joinThreshold
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
var labelIndex: [String: Int] = [:]   // labelVocab lookup, built once
var tokenIndex: [String: Int] = [:]

func internLabel(_ s: String) -> Int {
    if let i = labelIndex[s] { return i }
    meta.labelVocab.append(s); labelIndex[s] = meta.labelVocab.count - 1
    return meta.labelVocab.count - 1
}
func internToken(_ s: String) -> Int {
    if let i = tokenIndex[s] { return i }
    meta.tokenVocab.append(s); tokenIndex[s] = meta.tokenVocab.count - 1
    return meta.tokenVocab.count - 1
}

var aestheticsAvailable: Bool {
    if #available(macOS 15, *) { return config.signals.aesthetics } else { return false }
}

func syncIndex(items: [(path: String, modDate: Date?, tags: [String])],
               progress: (Int, Int) -> Void) {
    for (i, s) in meta.labelVocab.enumerated() { labelIndex[s] = i }
    for (i, s) in meta.tokenVocab.enumerated() { tokenIndex[s] = i }
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
        if rec.fpRow == nil { return true }
        if config.signals.faces && faceprintClass != nil && rec.faces == nil { return true }
        if config.signals.classify && rec.labels == nil { return true }
        if config.signals.ocr && rec.ocr == nil { return true }
        if aestheticsAvailable && rec.aes == nil { return true }
        return false
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
        let sigChanged = existing == nil || existing!.sig != sig
        var rec = sigChanged
            ? ImageRec(sig: sig, tags: it.tags, fpRow: nil, faces: nil,
                       labels: nil, ocr: nil, aes: nil)
            : existing!
        rec.sig = sig
        rec.tags = it.tags

        // Build the request list for exactly the missing signals — one decode.
        var requests: [VNRequest] = []
        var fpReq: VNGenerateImageFeaturePrintRequest?
        var faceReq: VNRequest?
        var classifyReq: VNClassifyImageRequest?
        var textReq: VNRecognizeTextRequest?
        var qualityReq: VNDetectFaceCaptureQualityRequest?
        var aesReq: VNRequest?
        if rec.fpRow == nil {
            let r = VNGenerateImageFeaturePrintRequest(); fpReq = r; requests.append(r)
        }
        if config.signals.faces, rec.faces == nil, let cls = faceprintClass,
           let r = cls.init() as? VNRequest {
            faceReq = r; requests.append(r)
            let q = VNDetectFaceCaptureQualityRequest(); qualityReq = q; requests.append(q)
        }
        if config.signals.classify, rec.labels == nil {
            let r = VNClassifyImageRequest(); classifyReq = r; requests.append(r)
        }
        if config.signals.ocr, rec.ocr == nil {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .fast
            r.usesLanguageCorrection = false
            textReq = r; requests.append(r)
        }
        if #available(macOS 15, *), aestheticsAvailable, rec.aes == nil {
            let r = VNCalculateImageAestheticsScoresRequest(); aesReq = r; requests.append(r)
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
                let found = faceVectors(faceReq)
                if meta.faceDim == 0, let f = found.first { meta.faceDim = f.vec.count }
                // Per-face capture quality via bbox IoU against the quality request.
                let qualityObs = (qualityReq?.results ?? [])
                func qualityFor(_ bbox: CGRect) -> Float? {
                    var best: (q: Float, iou: CGFloat)? = nil
                    for obs in qualityObs {
                        let overlap = iou(bbox, obs.boundingBox)
                        if overlap > 0.5, let q = obs.faceCaptureQuality,
                           overlap > (best?.iou ?? 0.5) { best = (q, overlap) }
                    }
                    return best?.q
                }
                var refs: [FaceRef] = []
                for f in found where f.vec.count == meta.faceDim {
                    try? faceFH.seek(toOffset: UInt64(meta.faceRows * meta.faceDim * 4))
                    faceFH.write(f.vec.withUnsafeBytes { Data($0) })
                    let q = qualityFor(f.bbox)
                    // Low-quality faces are the bridges that over-merge clusters:
                    // store the row but keep them out of clustering (cluster -1).
                    let cluster = (q ?? 1.0) >= config.faceQualityMin ? assignCluster(f.vec) : -1
                    refs.append(FaceRef(row: meta.faceRows, cluster: cluster, quality: q))
                    meta.faceRows += 1
                }
                rec.faces = refs
            }
            if let classifyReq {
                // Calibrated high-precision filter (the researched cold-start lever).
                let obs = (classifyReq.results ?? [])
                    .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
                rec.labels = obs.map { LabelRef(i: internLabel($0.identifier), c: $0.confidence) }
            }
            if let textReq {
                rec.ocr = ocrTokens(textReq).map(internToken)
            }
            if #available(macOS 15, *), let aesReq = aesReq as? VNCalculateImageAestheticsScoresRequest {
                if let a = aesReq.results?.first {
                    rec.aes = AesRef(score: a.overallScore, utility: a.isUtility)
                } else {
                    rec.aes = AesRef(score: 0, utility: false)  // present-but-empty
                }
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
            if share >= config.nameMinShare, concentration >= config.nameMinConcentration, inC > bestScore {
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

// ---- Co-occurrence model, recomputed from the persisted corpus each run
// (<10ms at ~4k images; no staleness). support[t] = images carrying t;
// pair[t][s] = images carrying both. P(t|s) = pair / support[s].
var coocSupport: [String: Int] = [:]
var coocPair: [String: [String: Int]] = [:]
for (_, rec) in meta.images where !rec.tags.isEmpty {
    let tags = Array(Set(rec.tags))
    for t in tags { coocSupport[t, default: 0] += 1 }
    for i in 0..<tags.count {
        for j in 0..<tags.count where i != j {
            coocPair[tags[i], default: [:]][tags[j], default: 0] += 1
        }
    }
}
func pCond(_ t: String, given s: String) -> Double {
    guard let sup = coocSupport[s], sup > 0 else { return 0 }
    return Double(coocPair[t]?[s] ?? 0) / Double(sup)
}
func hasSupport(_ t: String) -> Bool { (coocSupport[t] ?? 0) >= config.minSupport }

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

// kNN reference rows: every tagged image with a valid fp row (+ its classifier
// label vector for the ensemble similarity).
var refs: [(row: Int, tags: [String], labels: [Int: Float])] = []
if meta.fpDim > 0 {
    for (_, rec) in meta.images {
        if let r = rec.fpRow, r >= 0, !rec.tags.isEmpty {
            var lv: [Int: Float] = [:]
            for l in rec.labels ?? [] { lv[l.i] = l.c }
            refs.append((r, rec.tags, lv))
        }
    }
}

let taggedCount = refs.count
let coldStart = taggedCount < config.coldStartMinTagged
if coldStart { stderrLine("overlap-suggest: cold start (\(taggedCount) tagged) — classifier/OCR only") }

/// Sparse cosine between classifier-label vectors (semantic similarity channel of
/// the in-process ensemble; research α=.3 ensemble hit F1 .789 vs .743 single).
func labelSim(_ a: [Int: Float], _ b: [Int: Float]) -> Double {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var dot: Float = 0
    let (small, big) = a.count <= b.count ? (a, b) : (b, a)
    for (i, v) in small { if let w = big[i] { dot += v * w } }
    let na = a.values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    let nb = b.values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return na > 0 && nb > 0 ? Double(dot / (na * nb)) : 0
}

// Learned classifier→user-tag mapping: P(userTag | label) from images carrying
// both, accepted at support >= clsMapMinSupport and P >= clsMapMinP.
var labelImages: [Int: Int] = [:]
var labelTagPairs: [Int: [String: Int]] = [:]
for (_, rec) in meta.images where !rec.tags.isEmpty {
    for l in rec.labels ?? [] {
        labelImages[l.i, default: 0] += 1
        for t in Set(rec.tags) { labelTagPairs[l.i, default: [:]][t, default: 0] += 1 }
    }
}
var clsMap: [Int: [(tag: String, p: Double)]] = [:]
for (i, count) in labelImages where count >= config.clsMapMinSupport {
    var mapped: [(String, Double)] = []
    for (t, pair) in labelTagPairs[i] ?? [:] {
        let p = Double(pair) / Double(count)
        if p >= config.clsMapMinP { mapped.append((t, p)) }
    }
    if !mapped.isEmpty { clsMap[i] = mapped }
}

// OCR tag matching: lowercase leaf ("of/Fashion" -> "fashion") -> full tag, from
// the user's known vocabulary plus the corpus.
var leafToTag: [String: String] = [:]
for t in (req.knownTags ?? []) + Array(coocSupport.keys) {
    let leaf = (t.split(separator: "/").last.map(String.init) ?? t).lowercased()
    if leaf.count >= 3 { leafToTag[leaf] = t }
}
func editDistanceAtMost1(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let (s, l) = a.count <= b.count ? (Array(a), Array(b)) : (Array(b), Array(a))
    if l.count - s.count > 1 { return false }
    var i = 0, j = 0, edits = 0
    while i < s.count && j < l.count {
        if s[i] == l[j] { i += 1; j += 1; continue }
        edits += 1
        if edits > 1 { return false }
        if s.count == l.count { i += 1; j += 1 } else { j += 1 }
    }
    return edits + (l.count - j) + (s.count - i) <= 1
}

for file in req.files {
    guard let rec = meta.images[file.path] else { continue }
    let own = Set(file.tags)
    var channelScores: [String: [Double]] = [:]   // tag -> per-channel weighted scores

    // Aesthetics modifier: utility images (screenshots/receipts/docs) are where
    // scene-similarity misfires — damp kNN + classifier there so OCR dominates.
    let aesFactor = (rec.aes?.utility == true) ? 0.9 : 1.0

    // Target's sparse label vector (ensemble sim + channel C).
    var targetLabels: [Int: Float] = [:]
    for l in rec.labels ?? [] { targetLabels[l.i] = l.c }

    // Channel A — kNN borrowed tags; neighbor similarity is the in-process
    // ensemble: (1-α)·FeaturePrint + α·classifier-label cosine.
    if !coldStart, let blob = fpBlob, let tRow = rec.fpRow, tRow >= 0, meta.fpDim > 0,
       (tRow + 1) * meta.fpDim * 4 <= blob.size {
        let base = blob.ptr.assumingMemoryBound(to: Float.self)
        let dim = meta.fpDim
        func rowPtr(_ r: Int) -> UnsafePointer<Float> { UnsafePointer(base).advanced(by: r * dim) }
        let tv = rowPtr(tRow)
        let alpha = targetLabels.isEmpty ? 0 : config.labelEnsembleAlpha
        var scored: [(sim: Double, tags: [String])] = []
        scored.reserveCapacity(refs.count)
        for ref in refs where ref.row != tRow && (ref.row + 1) * dim * 4 <= blob.size {
            var d: Float = 0
            vDSP_dotpr(tv, 1, rowPtr(ref.row), 1, &d, vDSP_Length(dim))
            let sim = (1 - alpha) * Double(d) + alpha * labelSim(targetLabels, ref.labels)
            scored.append((sim, ref.tags))
        }
        let top = scored.sorted { $0.sim > $1.sim }.prefix(config.k)
        let total = top.reduce(0.0) { $0 + max(0, $1.sim) }
        if total > 0 {
            var weight: [String: Double] = [:]
            for n in top {
                for tag in Set(n.tags) where !own.contains(tag) {
                    weight[tag, default: 0] += max(0, n.sim)
                }
            }
            for (tag, w) in weight {
                channelScores[tag, default: []].append(config.weights.knn * aesFactor * min(1, w / total))
            }
        }
    }

    // Channel C — classifier labels mapped into the user's vocabulary.
    if !targetLabels.isEmpty {
        var clsScore: [String: Double] = [:]
        for (i, conf) in targetLabels {
            for (tag, p) in clsMap[i] ?? [] where !own.contains(tag) {
                clsScore[tag] = max(clsScore[tag] ?? 0, Double(conf) * p)
            }
        }
        for (tag, s) in clsScore {
            channelScores[tag, default: []].append(config.weights.cls * aesFactor * s)
        }
    }

    // Channel D — OCR text naming a tag: the highest-precision evidence we have.
    if let tokens = rec.ocr, !tokens.isEmpty {
        for tokenId in tokens where tokenId < meta.tokenVocab.count {
            let token = meta.tokenVocab[tokenId]
            if let tag = leafToTag[token], !own.contains(tag) {
                channelScores[tag, default: []].append(config.weights.ocr * 0.9)
            } else if token.count >= 5 {
                for (leaf, tag) in leafToTag
                where !own.contains(tag) && abs(leaf.count - token.count) <= 1
                    && editDistanceAtMost1(token, leaf) {
                    channelScores[tag, default: []].append(config.weights.ocr * 0.75)
                }
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
            channelScores[name, default: []].append(config.weights.face * conf)
        }
    }

    // Noisy-OR fusion across channels.
    var fused = channelScores.map { (tag: $0.key,
                                     score: 1 - $0.value.reduce(1.0) { $0 * (1 - min(1, $1)) }) }

    // Cooc rerank (research: +3pts precision at λ=.2): pull each candidate toward
    // the tags the corpus says accompany the OTHER candidates on this file.
    if config.lambda > 0, fused.count > 1 {
        let base = fused
        fused = base.map { cand in
            // Rerank only tags the corpus actually knows (support): pseudo-tags
            // like "Person N" and rare tags have no co-occurrence statistics, and
            // λ-blending them against zero would just erode good channel scores.
            guard hasSupport(cand.tag), !cand.tag.hasPrefix("Person ") else { return cand }
            var num = 0.0, den = 0.0
            for other in base where other.tag != cand.tag {
                num += other.score * pCond(cand.tag, given: other.tag)
                den += other.score
            }
            let coocScore = den > 0 ? num / den : cand.score
            return (cand.tag, (1 - config.lambda) * cand.score + config.lambda * coocScore)
        }
    }

    // Mutex-drop (research: free precision, P .797→.815): walking best-first, drop
    // a candidate that "never" co-occurs with an already-kept tag. Only applied
    // between tags with real corpus support; Person-N pseudo-tags are exempt.
    fused.sort { $0.score > $1.score }
    var kept: [(tag: String, score: Double)] = []
    for cand in fused {
        let isPseudo = cand.tag.hasPrefix("Person ")
        let conflicted = !isPseudo && hasSupport(cand.tag) && kept.contains { k in
            !k.tag.hasPrefix("Person ") && hasSupport(k.tag)
                && pCond(cand.tag, given: k.tag) < config.mutexFloor
                && pCond(k.tag, given: cand.tag) < config.mutexFloor
        }
        if !conflicted { kept.append(cand) }
    }

    let threshold = config.highPrecisionMode ? 0.60 : config.minConfidence
    var final = Array(kept.filter { $0.score >= threshold }.prefix(config.maxTagsPerFile))

    // Raw classifier fallback: when the personalized channels have nothing for
    // this file (or the whole corpus is cold), surface Apple's calibrated labels
    // as obj/<Label> — the researched cold-start answer (P≥.9 filter at store
    // time; far above the 0.221 bare-name CLIP baseline). Cap 3.
    if final.isEmpty, !targetLabels.isEmpty {
        let raw = targetLabels
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { (i, c) -> (tag: String, score: Double)? in
                guard i < meta.labelVocab.count else { return nil }
                let tag = "obj/\(meta.labelVocab[i].capitalized)"
                return own.contains(tag) ? nil : (tag, Double(c))
            }
        final = raw.filter { $0.score >= config.minConfidence }
    }

    for f in final {
        out.append(RawSuggestion(path: file.path, tag: f.tag,
                                 confidence: min(1, f.score), source: SOURCE))
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
