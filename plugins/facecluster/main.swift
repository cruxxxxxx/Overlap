import Foundation
import Vision

// Overlap "Face Groups" plugin.
//
// Groups the SELECTED images by who is in them. For each image it extracts one
// on-device Apple Vision faceprint per detected face (128-dim), clusters those
// faceprints across the selection, and emits one suggested "Person N" tag per
// cluster covering just the images that person appears in. Multi-face photos land
// in several clusters, so one image can get several Person chips.
//
// Uses Vision's face-embedding request, which is not part of the public Swift API,
// so it is reached through the Objective-C runtime (VNCreateFaceprintRequest /
// -faceprint). Fully on-device; no model download, no network. If the request is
// unavailable on a given OS, the plugin returns no suggestions rather than failing.
//
// The contract IS the JSON — structs mirror Sources/PluginContract.swift.

// MARK: - Wire contract

struct RequestFile: Codable {
    let path: String; let kind: String
    let ext: String; let tags: [String]
    let size: Int64?; let modDate: Date?; let createdDate: Date?
}
struct SuggestRequest: Codable {
    let protocolVersion: Int?
    let files: [RequestFile]
    let knownTags: [String]?
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

let JOIN_THRESHOLD = 0.84   // cosine to join a face to an existing person cluster
let MIN_CLUSTER = 2         // a person needs at least this many photos to suggest
let SOURCE = "facecluster"

// MARK: - Faceprint extraction (private Vision API via ObjC runtime)

/// Return one L2-normalized 128-d faceprint per detected face in the image, or []
/// if the file can't be read or the private request is unavailable.
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
              count > 0, data.count >= count * 4
        else { continue }
        var vec = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            for i in 0..<min(count, src.count) { vec[i] = src[i] }
        }
        var norm: Float = 0
        for x in vec { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in 0..<vec.count { vec[i] /= norm } }
        out.append(vec)
    }
    return out
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    var d: Float = 0
    for i in 0..<a.count { d += a[i] * b[i] }
    return d  // unit vectors → cosine
}

// MARK: - Clustering (centroid-linkage greedy; avoids single-linkage chaining)

struct Face { let path: String; let vec: [Float] }

final class Cluster {
    var sum: [Float]
    var centroid: [Float]
    var members: [Face] = []
    init(_ f: Face) { sum = f.vec; centroid = f.vec; members = [f] }
    func add(_ f: Face) {
        members.append(f)
        for i in 0..<sum.count { sum[i] += f.vec[i] }
        var norm: Float = 0
        for x in sum { norm += x * x }
        norm = norm.squareRoot()
        centroid = norm > 0 ? sum.map { $0 / norm } : sum
    }
}

// MARK: - Main

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("facecluster: bad request JSON\n".utf8))
    exit(1)
}

// Extract every face across the selection.
var faces: [Face] = []
for file in req.files where file.kind == "image" {
    for v in faceprints(file.path) { faces.append(Face(path: file.path, vec: v)) }
}

// Greedy centroid clustering.
var clusters: [Cluster] = []
for f in faces {
    var best: Cluster? = nil
    var bestSim = Float(JOIN_THRESHOLD)
    for c in clusters {
        let s = dot(f.vec, c.centroid)
        if s >= bestSim { bestSim = s; best = c }
    }
    if let b = best { b.add(f) } else { clusters.append(Cluster(f)) }
}

// Rank persons by how many distinct images they appear in (largest = Person 1).
func imageCount(_ c: Cluster) -> Int { Set(c.members.map { $0.path }).count }
let ranked = clusters
    .filter { imageCount($0) >= MIN_CLUSTER }
    .sorted { imageCount($0) > imageCount($1) }

var out: [RawSuggestion] = []
var seen = Set<String>()  // dedup path+tag (multi-face-same-person in one photo)
for (i, c) in ranked.enumerated() {
    let tag = "Person \(i + 1)"
    for f in c.members {
        let key = f.path + "\u{1}" + tag
        if seen.contains(key) { continue }
        seen.insert(key)
        // Confidence = this face's cohesion with the final person centroid.
        let conf = max(0, min(1, Double(dot(f.vec, c.centroid))))
        out.append(RawSuggestion(path: f.path, tag: tag, confidence: conf, source: SOURCE))
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp))
    ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
