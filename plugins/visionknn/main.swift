import Foundation
import Vision

// Overlap "Visual Neighbors" plugin.
//
// A real embed-and-nearest-neighbor suggester. For each selected file it computes
// an Apple Vision FeaturePrint (VNGenerateImageFeaturePrint — free, on-device, no
// model download), finds the k most visually-similar files in the user's tagged
// library, and suggests the tags those neighbors carry, weighted by similarity.
//
// This is the `wantsLibrary: true` pattern from docs/PLUGINS.md, implemented for
// real. Embeddings are cached on disk by path+modDate+size so only changed files
// are re-embedded between runs.
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

let K = 7                  // neighbors consulted per target
let MIN_CONFIDENCE = 0.30  // drop borrowed tags weaker than this
let MAX_TAGS_PER_FILE = 6
let SOURCE = "visionknn"

// MARK: - FeaturePrint embedding (unit-normalized Float vector)

/// Compute an L2-normalized FeaturePrint vector for an image file, or nil if the
/// file can't be read/embedded (unsupported, corrupt, not an image).
func embed(_ path: String) -> [Float]? {
    let url = URL(fileURLWithPath: path)
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: url, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return nil
    }
    guard let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }
    let count = obs.elementCount
    var vec = [Float](repeating: 0, count: count)
    // FeaturePrint elements are Float32 (elementType == .float). Copy raw bytes out.
    obs.data.withUnsafeBytes { raw in
        let src = raw.bindMemory(to: Float.self)
        for i in 0..<min(count, src.count) { vec[i] = src[i] }
    }
    var norm: Float = 0
    for x in vec { norm += x * x }
    norm = norm.squareRoot()
    if norm > 0 { for i in 0..<vec.count { vec[i] /= norm } }
    return vec
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count else { return 0 }
    var dot: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i] }
    return Double(dot)  // inputs are already unit vectors
}

// MARK: - Disk cache: path -> {sig, vec}

struct CacheEntry: Codable { let sig: String; let vec: [Float] }

func cacheURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Overlap", isDirectory: true)
        .appendingPathComponent("PluginCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("visionknn-featureprint.json")
}

/// size:mtime fingerprint so a changed file invalidates its cached vector.
func signature(path: String, modDate: Date?) -> String {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs?[.size] as? Int64) ?? -1
    let mtime = (modDate ?? (attrs?[.modificationDate] as? Date))?.timeIntervalSince1970 ?? -1
    return "\(size):\(Int(mtime))"
}

var cache: [String: CacheEntry] = {
    guard let data = try? Data(contentsOf: cacheURL()),
          let map = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
    else { return [:] }
    return map
}()

/// Embed via cache; returns nil on unreadable files.
func embedCached(path: String, modDate: Date?) -> [Float]? {
    let sig = signature(path: path, modDate: modDate)
    if let hit = cache[path], hit.sig == sig { return hit.vec }
    guard let vec = embed(path) else { return nil }
    cache[path] = CacheEntry(sig: sig, vec: vec)
    return vec
}

func saveCache() {
    if let data = try? JSONEncoder().encode(cache) {
        try? data.write(to: cacheURL())
    }
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("visionknn: bad request JSON\n".utf8))
    exit(1)
}

let library = req.library ?? []

// Embed the tagged library (cached). Skip items with no tags or no vector.
var refVecs: [(vec: [Float], tags: [String])] = []
for item in library where !item.tags.isEmpty {
    if let v = embedCached(path: item.path, modDate: item.modDate) {
        refVecs.append((v, item.tags))
    }
}

var out: [RawSuggestion] = []

for file in req.files {
    guard let tv = embedCached(path: file.path, modDate: file.modDate) else { continue }
    let own = Set(file.tags)

    // Score every reference by cosine, keep the top K.
    let top = refVecs
        .map { (sim: cosine(tv, $0.vec), tags: $0.tags) }
        .sorted { $0.sim > $1.sim }
        .prefix(K)
    let total = top.reduce(0.0) { $0 + max(0, $1.sim) }
    guard total > 0 else { continue }

    // Weight each tag by the summed similarity of neighbors that carry it.
    var weight: [String: Double] = [:]
    for n in top {
        for tag in Set(n.tags) where !own.contains(tag) {
            weight[tag, default: 0] += max(0, n.sim)
        }
    }
    let ranked = weight
        .map { (tag: $0.key, conf: $0.value / total) }
        .filter { $0.conf >= MIN_CONFIDENCE }
        .sorted { $0.conf > $1.conf }
        .prefix(MAX_TAGS_PER_FILE)
    for r in ranked {
        out.append(RawSuggestion(path: file.path, tag: r.tag,
                                 confidence: min(1, r.conf), source: SOURCE))
    }
}

saveCache()

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
