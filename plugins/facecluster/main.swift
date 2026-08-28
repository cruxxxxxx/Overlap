import Foundation
import Vision
import Accelerate

// Overlap "Face Groups" plugin.
//
// Builds a PERSISTENT identity clustering over every face in the library and
// suggests a stable identity tag for each selected photo:
//
//  • Every face is embedded (Apple Vision faceprint, 128-d, on-device) and assigned
//    to a stable cluster. Cluster N is the same person across runs.
//  • A cluster's NAME is learned from the tags its photos already carry: the tag
//    most *concentrated* in this cluster (a person name like "Alex" sits on one
//    person's photos; a category like "Fashion" is spread across everyone, so it's
//    ignored). Until you name it, the cluster is just "Person N".
//  • Selecting a photo suggests its people's tags — click to apply. Rename
//    "Person 3" → "Alex" with the app's normal tag rename and every photo updates;
//    next run the plugin sees "Alex" concentrated in cluster 3 and adopts it, so new
//    photos of that person suggest "Alex". Over-split (one person in two clusters)
//    self-heals once you rename both to the same name.
//
// The face-embedding request isn't in the public Swift API, so it's reached via the
// ObjC runtime. Fully local; unavailable request → no suggestions, never a crash.
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
}
struct SuggestResponse: Codable {
    let protocolVersion: Int
    let suggestions: [RawSuggestion]
}

// MARK: - Tunables

let JOIN_THRESHOLD: Float = 0.84    // cosine to join a face to an existing cluster
let NAME_MIN_SHARE = 0.5            // a name tag must be on ≥ this fraction of a cluster
let NAME_MIN_CONCENTRATION = 0.6    // …and ≥ this fraction of all its uses are in-cluster
let SOURCE = "facecluster"

// MARK: - Faceprint extraction (private Vision API via ObjC runtime)

/// L2-normalized 128-d faceprints for every detected face, or [] on failure.
func faceprints(_ path: String) -> [[Float]] {
    guard let cls = NSClassFromString("VNCreateFaceprintRequest") as? NSObject.Type else { return [] }
    let request = cls.init()
    guard let visionRequest = request as? VNRequest else { return [] }
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do { try handler.perform([visionRequest]) } catch { return [] }
    guard let faces = visionRequest.results as? [VNFaceObservation] else { return [] }
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
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(count)); norm = norm.squareRoot()
        if norm > 0 { var inv = 1 / norm; vDSP_vsmul(vec, 1, &inv, &vec, 1, vDSP_Length(count)) }
        out.append(vec)
    }
    return out
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var d: Float = 0
    a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
        vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &d, vDSP_Length(a.count)) } }
    return d
}

func signature(path: String, modDate: Date?) -> String {
    if let m = modDate { return "m:\(Int(m.timeIntervalSince1970))" }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
        .flatMap { $0 }?.timeIntervalSince1970 ?? -1
    return "s:\(Int(mtime))"
}

// MARK: - Persistent state (meta.json + mmap'd faces.bin)
//
// Face vectors live in faces.bin — packed float32, one row per face, appended in
// row order and memory-mapped at query time (no JSON float parsing). meta.json
// keeps only small things: per-image {sig, [(row, cluster)], tags} plus cluster
// centroids-in-progress. Cluster sums stay in meta (a few hundred × dim — small).

struct FaceRef: Codable { var row: Int; var cluster: Int }
struct ImageEntry: Codable { var sig: String; var faces: [FaceRef]; var tags: [String] }
struct ClusterState: Codable { var sum: [Float]; var count: Int }
struct Meta: Codable {
    var dim: Int = 0
    var rows: Int = 0                       // rows written to faces.bin
    var images: [String: ImageEntry] = [:]
    var clusters: [Int: ClusterState] = [:]
    var nextCluster: Int = 1
}

let cacheDir: URL = {
    // OVERLAP_PLUGIN_CACHE overrides the cache root (tests use a throwaway dir —
    // NSApplicationSupportDirectory ignores $HOME, so this is the only safe way
    // to isolate a run from the real index).
    let base: URL
    if let override = ProcessInfo.processInfo.environment["OVERLAP_PLUGIN_CACHE"] {
        base = URL(fileURLWithPath: override, isDirectory: true)
            .appendingPathComponent("facecluster", isDirectory: true)
    } else {
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/PluginCache/facecluster", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}()
let metaURL = cacheDir.appendingPathComponent("meta.json")
let binURL = cacheDir.appendingPathComponent("faces.bin")

// One-time migration from the previous format (vectors as JSON floats in meta):
// stream the old vecs into faces.bin and keep everything else, so an existing
// index doesn't need a full re-embed of the library.
struct OldFace: Codable { var vec: [Float]; var cluster: Int }
struct OldEntry: Codable { var sig: String; var faces: [OldFace]; var tags: [String] }
struct OldMeta: Codable {
    var dim: Int; var images: [String: OldEntry]
    var clusters: [Int: ClusterState]; var nextCluster: Int
}

func migrate(_ old: OldMeta) -> Meta {
    var m = Meta(dim: old.dim, rows: 0, images: [:],
                 clusters: old.clusters, nextCluster: old.nextCluster)
    FileManager.default.createFile(atPath: binURL.path, contents: nil)
    guard let fh = try? FileHandle(forWritingTo: binURL) else { return Meta() }
    defer { try? fh.close() }
    for (path, e) in old.images {
        var refs: [FaceRef] = []
        for f in e.faces where f.vec.count == old.dim {
            fh.write(f.vec.withUnsafeBytes { Data($0) })
            refs.append(FaceRef(row: m.rows, cluster: f.cluster))
            m.rows += 1
        }
        m.images[path] = ImageEntry(sig: e.sig, faces: refs, tags: e.tags)
    }
    return m
}

var meta: Meta = {
    guard let d = try? Data(contentsOf: metaURL) else { return Meta() }
    if let m = try? JSONDecoder().decode(Meta.self, from: d) { return m }
    if let old = try? JSONDecoder().decode(OldMeta.self, from: d) {
        let m = migrate(old)
        if let enc = try? JSONEncoder().encode(m) { try? enc.write(to: metaURL) }
        FileHandle.standardError.write(Data("facecluster: migrated index to faces.bin\n".utf8))
        return m
    }
    return Meta()
}()
func saveMeta() { if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL) } }

func centroid(_ c: ClusterState) -> [Float] {
    var n: Float = 0; vDSP_svesq(c.sum, 1, &n, vDSP_Length(c.sum.count)); n = n.squareRoot()
    return n > 0 ? c.sum.map { $0 / n } : c.sum
}

/// Assign a face vector to the nearest cluster (or a new one) and update centroid.
func assign(_ vec: [Float]) -> Int {
    var best = -1; var bestSim = JOIN_THRESHOLD
    for (id, c) in meta.clusters {
        let s = cosine(vec, centroid(c))
        if s >= bestSim { bestSim = s; best = id }
    }
    if best == -1 {
        best = meta.nextCluster; meta.nextCluster += 1
        meta.clusters[best] = ClusterState(sum: vec, count: 1)
    } else {
        var c = meta.clusters[best]!
        for i in 0..<c.sum.count { c.sum[i] += vec[i] }; c.count += 1
        meta.clusters[best] = c
    }
    return best
}

/// Bring the index up to date: embed new/changed images' faces and cluster them;
/// refresh tags for everything (labels are learned from tags).
func syncIndex(items: [(path: String, modDate: Date?, tags: [String])], progress: (Int, Int) -> Void) {
    let todo = items.filter { meta.images[$0.path]?.sig != signature(path: $0.path, modDate: $0.modDate) }
    var done = 0
    if !FileManager.default.fileExists(atPath: binURL.path) {
        FileManager.default.createFile(atPath: binURL.path, contents: nil)
    }
    guard let fh = try? FileHandle(forUpdating: binURL) else { return }
    defer { try? fh.close() }
    _ = try? fh.seekToEnd()
    for it in items {
        let sig = signature(path: it.path, modDate: it.modDate)
        if let e = meta.images[it.path], e.sig == sig {
            if e.tags != it.tags { meta.images[it.path]?.tags = it.tags }
            continue
        }
        let faces = faceprints(it.path)
        if meta.dim == 0, let f = faces.first { meta.dim = f.count }
        var refs: [FaceRef] = []
        for f in faces where f.count == meta.dim {
            fh.write(f.withUnsafeBytes { Data($0) })   // append row to faces.bin
            refs.append(FaceRef(row: meta.rows, cluster: assign(f)))
            meta.rows += 1
        }
        meta.images[it.path] = ImageEntry(sig: sig, faces: refs, tags: it.tags)
        done += 1
        if done % 25 == 0 { saveMeta(); progress(done, todo.count) }
    }
    if todo.count > 0 { saveMeta() }
}

/// Learn each cluster's display name from the tags its member images carry: the tag
/// most concentrated in the cluster (person-like), else "Person <id>".
func clusterNames() -> [Int: String] {
    // How many images (total) carry each tag, and how many per cluster.
    var globalTagCount: [String: Int] = [:]
    var clusterTagCount: [Int: [String: Int]] = [:]
    var clusterSize: [Int: Int] = [:]
    for (_, entry) in meta.images {
        let clustersHere = Set(entry.faces.map { $0.cluster })
        for c in clustersHere { clusterSize[c, default: 0] += 1 }
        for tag in Set(entry.tags) {
            globalTagCount[tag, default: 0] += 1
            for c in clustersHere { clusterTagCount[c, default: [:]][tag, default: 0] += 1 }
        }
    }
    var names: [Int: String] = [:]
    for (c, size) in clusterSize {
        var bestTag: String? = nil; var bestScore = 0
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
    FileHandle.standardError.write(Data("facecluster: bad request JSON\n".utf8))
    exit(1)
}

// Dedupe library + targets by path (a selected file appears in both) and union
// their tags, so a target's copy can't clobber the library's authoritative tags.
var modByPath: [String: Date?] = [:]
var tagsByPath: [String: Set<String>] = [:]
for it in (req.library ?? []) { modByPath[it.path] = it.modDate; tagsByPath[it.path, default: []].formUnion(it.tags) }
for f in req.files { modByPath[f.path] = f.modDate; tagsByPath[f.path, default: []].formUnion(f.tags) }
let need = tagsByPath.map { (path: $0.key, modDate: modByPath[$0.key] ?? nil, tags: Array($0.value)) }
syncIndex(items: need) { done, total in
    FileHandle.standardError.write(Data("Building face index… \(done)/\(total)\n".utf8))
}

let names = clusterNames()
var out: [RawSuggestion] = []
let dim = meta.dim
if dim > 0, let fh = try? FileHandle(forReadingFrom: binURL) {
    let fd = fh.fileDescriptor
    let size = Int(lseek(fd, 0, SEEK_END))
    let raw = size >= dim * 4 ? mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0) : nil
    let base = (raw != nil && raw != MAP_FAILED) ? raw!.assumingMemoryBound(to: Float.self) : nil

    for file in req.files {
        guard let entry = meta.images[file.path] else { continue }
        let own = Set(file.tags)
        var seen = Set<String>()
        for face in entry.faces {
            guard let name = names[face.cluster], !own.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            // Confidence = this face's cohesion with its cluster centroid, read
            // straight off the mmap'd row (no vectors in meta anymore).
            var conf = 0.7
            if let base, (face.row + 1) * dim * 4 <= size,
               let cluster = meta.clusters[face.cluster] {
                let cent = centroid(cluster)
                var d: Float = 0
                cent.withUnsafeBufferPointer { pc in
                    vDSP_dotpr(UnsafePointer(base).advanced(by: face.row * dim), 1,
                               pc.baseAddress!, 1, &d, vDSP_Length(dim))
                }
                conf = max(0, min(1, Double(d)))
            }
            out.append(RawSuggestion(path: file.path, tag: name, confidence: conf, source: SOURCE))
        }
    }
    if let raw, raw != MAP_FAILED { munmap(raw, size) }
    try? fh.close()
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
