import Foundation
import Vision
import Accelerate

// Overlap "Visual Neighbors" plugin.
//
// For each selected file it computes an Apple Vision FeaturePrint
// (VNGenerateImageFeaturePrint — free, on-device, no model download), finds the k
// most visually-similar files in the user's tagged library, and suggests the tags
// those neighbors carry, weighted by similarity.
//
// SCALE: embeddings live in a plugin-owned on-disk index — a packed float32 blob
// (`index.bin`, one 768-float row per image) that is **memory-mapped**, not parsed,
// plus a small `meta.json` mapping path → row + change-signature. A cold run
// appends new rows; a warm run mmaps the blob (near-zero load regardless of size)
// and scores with Accelerate/vDSP dot products. This keeps a per-click Suggest at
// tens of ms into the ~1M-image range, instead of re-parsing a giant JSON each time.
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

let K = 7
let MIN_CONFIDENCE = 0.30
let MAX_TAGS_PER_FILE = 6
let SOURCE = "visionknn"

// MARK: - FeaturePrint embedding (unit-normalized Float vector)

func embed(_ path: String) -> [Float]? {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do { try handler.perform([request]) } catch { return nil }
    guard let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }
    let count = obs.elementCount
    var vec = [Float](repeating: 0, count: count)
    obs.data.withUnsafeBytes { raw in
        let src = raw.bindMemory(to: Float.self)
        for i in 0..<min(count, src.count) { vec[i] = src[i] }
    }
    var norm: Float = 0
    vDSP_svesq(vec, 1, &norm, vDSP_Length(count))   // sum of squares
    norm = norm.squareRoot()
    if norm > 0 { var inv = 1 / norm; vDSP_vsmul(vec, 1, &inv, &vec, 1, vDSP_Length(count)) }
    return vec
}

/// mtime fingerprint so a changed file invalidates its cached row. The host passes
/// each file's modDate in the request, so the common path needs NO stat() — critical
/// at scale (one syscall per library item per click would dominate the latency). Only
/// files with no supplied date fall back to a stat.
func signature(path: String, modDate: Date?) -> String {
    if let m = modDate { return "m:\(Int(m.timeIntervalSince1970))" }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
        .flatMap { $0 }?.timeIntervalSince1970 ?? -1
    return "s:\(Int(mtime))"
}

// MARK: - On-disk mmap index (index.bin + meta.json)

// Each embedded image: its row in index.bin, a change-signature, and its tags.
// Persisting tags here makes the plugin the source of truth for the corpus, so the
// host only re-sends the library when it actually changed (see the empty-library
// fast path in main) — no multi-MB pipe on every click.
struct Entry: Codable { var row: Int; var sig: String; var tags: [String] }
struct Meta: Codable { var dim: Int; var entries: [String: Entry] }

let indexDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Overlap/PluginCache/visionknn", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}()
let binURL = indexDir.appendingPathComponent("index.bin")
let metaURL = indexDir.appendingPathComponent("meta.json")

var meta: Meta = {
    guard let d = try? Data(contentsOf: metaURL),
          let m = try? JSONDecoder().decode(Meta.self, from: d) else { return Meta(dim: 0, entries: [:]) }
    return m
}()

func saveMeta() {
    if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL) }
}

struct SyncItem { let path: String; let modDate: Date?; let tags: [String] }

/// Bring the index up to date for the given items: embed new/changed files (row
/// appended or overwritten in place) and record each item's tags. Vectors already
/// current are left alone; only their tags are refreshed if they changed. This is
/// how the persisted corpus stays authoritative without the host re-sending it.
func syncIndex(items: [SyncItem], progress: (Int, Int) -> Void) {
    if !FileManager.default.fileExists(atPath: binURL.path) {
        FileManager.default.createFile(atPath: binURL.path, contents: nil)
    }
    guard let fh = try? FileHandle(forUpdating: binURL) else { return }
    defer { try? fh.close() }

    let toEmbed = items.filter { meta.entries[$0.path]?.sig != signature(path: $0.path, modDate: $0.modDate) }
    var fresh = 0
    for it in items {
        let sig = signature(path: it.path, modDate: it.modDate)
        // Vector already current: just refresh tags if they changed, no embed.
        if let e = meta.entries[it.path], e.sig == sig {
            if e.tags != it.tags { meta.entries[it.path] = Entry(row: e.row, sig: sig, tags: it.tags) }
            continue
        }
        guard let vec = embed(it.path) else { continue }

        // First-ever vector sets the dimension; a dimension change (OS/model
        // revision) invalidates the whole blob — rebuild from scratch.
        if meta.dim == 0 { meta.dim = vec.count }
        else if vec.count != meta.dim {
            try? fh.truncate(atOffset: 0); meta = Meta(dim: vec.count, entries: [:])
        }

        let bytesPerRow = meta.dim * 4
        let row = meta.entries[it.path]?.row ?? (Int((try? fh.seekToEnd()) ?? 0) / bytesPerRow)
        try? fh.seek(toOffset: UInt64(row * bytesPerRow))
        fh.write(vec.withUnsafeBytes { Data($0) })
        meta.entries[it.path] = Entry(row: row, sig: sig, tags: it.tags)

        fresh += 1
        if fresh % 25 == 0 { saveMeta(); progress(fresh, toEmbed.count) }
    }
    if fresh > 0 { saveMeta() }
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("visionknn: bad request JSON\n".utf8))
    exit(1)
}

// Sync the corpus. The host sends `library` only when it changed (otherwise an
// empty list — the persisted index is authoritative), plus always the targets so a
// freshly-selected untagged file gets embedded. Tags are recorded here so queries
// don't need the host to re-send the library each click.
var items = (req.library ?? []).map { SyncItem(path: $0.path, modDate: $0.modDate, tags: $0.tags) }
items.append(contentsOf: req.files.map { SyncItem(path: $0.path, modDate: $0.modDate, tags: $0.tags) })
syncIndex(items: items) { done, total in
    FileHandle.standardError.write(Data("Building suggestion index… \(done)/\(total)\n".utf8))
}

// Memory-map the vector blob for querying (near-zero load; OS pages in on demand).
let dim = meta.dim
var out: [RawSuggestion] = []
if dim > 0, let fh = try? FileHandle(forReadingFrom: binURL) {
    let fd = fh.fileDescriptor
    let size = Int(lseek(fd, 0, SEEK_END))
    if size >= dim * 4, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED {
        let base = raw.assumingMemoryBound(to: Float.self)
        func rowPtr(_ r: Int) -> UnsafePointer<Float> { UnsafePointer(base).advanced(by: r * dim) }

        // Score against the whole persisted corpus — every embedded image that has
        // tags — regardless of what the host sent this call.
        let refs: [(row: Int, tags: [String])] = meta.entries.values.compactMap {
            $0.tags.isEmpty ? nil : ($0.row, $0.tags)
        }

        for file in req.files {
            guard let e = meta.entries[file.path] else { continue }
            let tv = rowPtr(e.row)
            let own = Set(file.tags)

            // Cosine = dot (rows are unit-normalized). vDSP over the mmap.
            var scored = [(sim: Float, tags: [String])]()
            scored.reserveCapacity(refs.count)
            for ref in refs where ref.row != e.row {   // skip self
                var d: Float = 0
                vDSP_dotpr(tv, 1, rowPtr(ref.row), 1, &d, vDSP_Length(dim))
                scored.append((d, ref.tags))
            }
            let top = scored.sorted { $0.sim > $1.sim }.prefix(K)
            let total = top.reduce(0.0) { $0 + max(0, Double($1.sim)) }
            guard total > 0 else { continue }

            var weight: [String: Double] = [:]
            for n in top {
                for tag in Set(n.tags) where !own.contains(tag) {
                    weight[tag, default: 0] += max(0, Double(n.sim))
                }
            }
            let ranked = weight.map { (tag: $0.key, conf: $0.value / total) }
                .filter { $0.conf >= MIN_CONFIDENCE }
                .sorted { $0.conf > $1.conf }
                .prefix(MAX_TAGS_PER_FILE)
            for r in ranked {
                out.append(RawSuggestion(path: file.path, tag: r.tag,
                                         confidence: min(1, r.conf), source: SOURCE))
            }
        }
        munmap(raw, size)
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
