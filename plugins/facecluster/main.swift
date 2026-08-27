import Foundation
import Vision
import Accelerate

// Overlap "Face Groups" plugin.
//
// Two behaviors over the selected images, both on-device (Apple Vision faceprints,
// 128-d, via the ObjC runtime — the embedding request isn't in the public Swift API):
//
//  1. MATCH — a selected face that resembles a person you've already named (any
//     library image carrying a `person/<name>` tag) yields a normal single-click
//     suggestion of that `person/<name>` tag. This is how newly added photos of a
//     known person get auto-labeled.
//
//  2. GROUP — faces that match nobody are clustered among the selection and emitted
//     as `group: true` "Person N" handles. These are NOT tags to apply: the host
//     turns them into select-the-members-then-name affordances. Naming writes a real
//     `person/<name>` tag, which this plugin then learns for next time.
//
// A persistent, memory-mapped faceprint index (faces.bin + meta.json) means only
// new/changed images are re-embedded. Fully local; if the private request is
// unavailable the plugin returns no suggestions rather than failing.
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
    var group: Bool? = nil     // true = a cluster handle to name, not a tag to apply
}
struct SuggestResponse: Codable {
    let protocolVersion: Int
    let suggestions: [RawSuggestion]
}

// MARK: - Tunables

let PERSON_PREFIX = "person/"   // namespace that marks a face identity
let MATCH_THRESHOLD: Float = 0.84   // cosine to accept a target face as a known person
let JOIN_THRESHOLD: Float = 0.84    // cosine to join two unmatched faces into one group
let MAX_GROUPS = 12
let SOURCE = "facecluster"

// MARK: - Faceprint extraction (private Vision API via ObjC runtime)

struct FoundFace { let vec: [Float]; let bbox: [Double] }

/// One L2-normalized 128-d faceprint per detected face (+ its normalized bbox), or
/// [] if the file can't be read or the private request is unavailable.
func faceprints(_ path: String) -> [FoundFace] {
    guard let cls = NSClassFromString("VNCreateFaceprintRequest") as? NSObject.Type else { return [] }
    let request = cls.init()
    guard let visionRequest = request as? VNRequest else { return [] }
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do { try handler.perform([visionRequest]) } catch { return [] }
    guard let faces = visionRequest.results as? [VNFaceObservation] else { return [] }

    var out: [FoundFace] = []
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
        let b = obs.boundingBox
        out.append(FoundFace(vec: vec, bbox: [b.origin.x, b.origin.y, b.size.width, b.size.height]))
    }
    return out
}

func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Float {
    var d: Float = 0; vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(n)); return d
}

/// mtime fingerprint (host-supplied modDate → no stat on the hot path).
func signature(path: String, modDate: Date?) -> String {
    if let m = modDate { return "m:\(Int(m.timeIntervalSince1970))" }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
        .flatMap { $0 }?.timeIntervalSince1970 ?? -1
    return "s:\(Int(mtime))"
}

// MARK: - Persistent mmap faceprint index

struct FaceRow: Codable { var row: Int; var bbox: [Double] }
// `tags` is persisted so identity labels (person/<name>) survive when the host sends
// an empty library on unchanged clicks — the index is the source of truth.
struct ImageEntry: Codable { var sig: String; var faces: [FaceRow]; var tags: [String] }
struct Meta: Codable { var dim: Int; var images: [String: ImageEntry] }

let indexDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Overlap/PluginCache/facecluster", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}()
let binURL = indexDir.appendingPathComponent("faces.bin")
let metaURL = indexDir.appendingPathComponent("meta.json")

var meta: Meta = {
    guard let d = try? Data(contentsOf: metaURL),
          let m = try? JSONDecoder().decode(Meta.self, from: d) else { return Meta(dim: 0, images: [:]) }
    return m
}()
func saveMeta() { if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL) } }

/// Ensure faceprints for `items` are in the index; append rows for new/changed
/// images (old rows orphaned — harmless). Progress on stderr.
func syncIndex(items: [(path: String, modDate: Date?, tags: [String])], progress: (Int, Int) -> Void) {
    if !FileManager.default.fileExists(atPath: binURL.path) {
        FileManager.default.createFile(atPath: binURL.path, contents: nil)
    }
    guard let fh = try? FileHandle(forUpdating: binURL) else { return }
    defer { try? fh.close() }
    let todo = items.filter { meta.images[$0.path]?.sig != signature(path: $0.path, modDate: $0.modDate) }
    var done = 0
    for it in items {
        let sig = signature(path: it.path, modDate: it.modDate)
        // Faces unchanged: just refresh persisted tags (labels) if they changed.
        if let e = meta.images[it.path], e.sig == sig {
            if e.tags != it.tags { meta.images[it.path]?.tags = it.tags }
            continue
        }
        let faces = faceprints(it.path)
        if meta.dim == 0, let f = faces.first { meta.dim = f.vec.count }
        var rows: [FaceRow] = []
        if meta.dim > 0 {
            for f in faces where f.vec.count == meta.dim {
                let row = Int((try? fh.seekToEnd()) ?? 0) / (meta.dim * 4)
                fh.write(f.vec.withUnsafeBytes { Data($0) })
                rows.append(FaceRow(row: row, bbox: f.bbox))
            }
        }
        meta.images[it.path] = ImageEntry(sig: sig, faces: rows, tags: it.tags)
        done += 1
        if done % 25 == 0 { saveMeta(); progress(done, todo.count) }
    }
    if done > 0 { saveMeta() }
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("facecluster: bad request JSON\n".utf8))
    exit(1)
}

let library = req.library ?? []

// Index every library + target image (faceprints for new/changed; tags always
// refreshed). Tags are persisted so labels survive an empty-library click.
var need: [(path: String, modDate: Date?, tags: [String])] = library.map { ($0.path, $0.modDate, $0.tags) }
need.append(contentsOf: req.files.map { ($0.path, $0.modDate, $0.tags) })
syncIndex(items: need) { done, total in
    FileHandle.standardError.write(Data("Building face index… \(done)/\(total)\n".utf8))
}

let dim = meta.dim
var out: [RawSuggestion] = []

if dim > 0, let fh = try? FileHandle(forReadingFrom: binURL) {
    let fd = fh.fileDescriptor
    let size = Int(lseek(fd, 0, SEEK_END))
    if size >= dim * 4, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED {
        let base = raw.assumingMemoryBound(to: Float.self)
        func rowPtr(_ r: Int) -> UnsafePointer<Float> { UnsafePointer(base).advanced(by: r * dim) }

        // Labeled faces come from the PERSISTED index (works on empty-library clicks):
        // an image with exactly one person/<name> tag anchors that identity for each
        // of its faces. (One person tag avoids the ambiguity of which face maps to
        // which name in a group photo.)
        var labeled: [(row: Int, name: String)] = []
        for (_, entry) in meta.images {
            let people = entry.tags.filter { $0.hasPrefix(PERSON_PREFIX) }
            guard people.count == 1 else { continue }
            for f in entry.faces { labeled.append((f.row, people[0])) }
        }

        // For each selected image, match or collect its faces.
        struct Unmatched { let path: String; let row: Int }
        var unmatched: [Unmatched] = []
        var perFileMatched = Set<String>()   // path\u{1}tag already emitted

        for file in req.files {
            guard let entry = meta.images[file.path] else { continue }
            let own = Set(file.tags)
            for f in entry.faces {
                let tv = rowPtr(f.row)
                var best: (name: String, sim: Float)? = nil
                for l in labeled {
                    let s = dot(tv, rowPtr(l.row), dim)
                    if s >= MATCH_THRESHOLD, s > (best?.sim ?? MATCH_THRESHOLD) { best = (l.name, s) }
                }
                if let b = best {
                    let key = file.path + "\u{1}" + b.name
                    if !own.contains(b.name), !perFileMatched.contains(key) {
                        perFileMatched.insert(key)
                        out.append(RawSuggestion(path: file.path, tag: b.name,
                                                 confidence: Double(b.sim), source: SOURCE, group: false))
                    }
                } else {
                    unmatched.append(Unmatched(path: file.path, row: f.row))
                }
            }
        }

        // Cluster the leftover (nobody-matched) faces → "Person N" group handles.
        final class Cluster { var sum: [Float]; var cent: [Float]; var paths: [String] = []
            init(_ v: [Float], _ p: String) { sum = v; cent = v; paths = [p] }
            func add(_ v: [Float], _ p: String) {
                paths.append(p); for i in 0..<sum.count { sum[i] += v[i] }
                var n: Float = 0; vDSP_svesq(sum, 1, &n, vDSP_Length(sum.count)); n = n.squareRoot()
                cent = n > 0 ? sum.map { $0 / n } : sum
            }
        }
        var clusters: [Cluster] = []
        for u in unmatched {
            let v = Array(UnsafeBufferPointer(start: rowPtr(u.row), count: dim))
            var best: Cluster? = nil; var bestSim = JOIN_THRESHOLD
            for c in clusters { let s = dot(v, c.cent, dim); if s >= bestSim { bestSim = s; best = c } }
            if let b = best { b.add(v, u.path) } else { clusters.append(Cluster(v, u.path)) }
        }
        let ranked = clusters
            .sorted { Set($0.paths).count > Set($1.paths).count }
            .prefix(MAX_GROUPS)
        // Neutral, obviously-a-placeholder label — never a fake identity. The tag is
        // only an internal handle; the host shows it as a "group to name", and naming
        // replaces it with a real person/<name>. It is never applied as-is.
        for (i, c) in ranked.enumerated() {
            let tag = "Group \(i + 1)"
            for p in Set(c.paths) {
                out.append(RawSuggestion(path: p, tag: tag, confidence: 0.6, source: SOURCE, group: true))
            }
        }
        munmap(raw, size)
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))

func dot(_ a: [Float], _ b: [Float], _ n: Int) -> Float {
    a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in dot(pa.baseAddress!, pb.baseAddress!, n) } }
}
