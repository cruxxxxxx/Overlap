import Foundation

// Overlap MOCK clustering plugin.
//
// Stands in for a real embed-and-cluster plugin so the cluster-chip UX can be
// exercised without an embedding model: the selection is bucketed into 2–4
// "clusters" by a stable hash of each filename, and every bucket becomes one
// suggested tag covering just its member files. The groups are arbitrary but
// deterministic — the same selection always clusters the same way, so
// apply/undo/preview behave repeatably.
//
// The contract IS the JSON — structs mirror Sources/PluginContract.swift.

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

// Swift's Hashable is seed-randomized per process; clustering must be stable
// across runs, so use djb2 over the filename bytes.
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    // djb2 alone lands similar short names in one bucket; mix the bits so the
    // modulo spreads them (murmur3-style finalizer).
    h ^= h >> 33; h = h &* 0xff51_afd7_ed55_8ccd; h ^= h >> 33
    return h
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("mockcluster: bad request JSON\n".utf8))
    exit(1)
}

let clusterNames = ["Cluster Alpha", "Cluster Beta", "Cluster Gamma", "Cluster Delta"]
let clusterCount = min(clusterNames.count, max(2, req.files.count / 4))

let suggestions = req.files.map { f -> RawSuggestion in
    let name = URL(fileURLWithPath: f.path).lastPathComponent
    let bucket = Int(stableHash(name) % UInt64(clusterCount))
    return RawSuggestion(path: f.path, tag: clusterNames[bucket],
                         confidence: 0.9 - 0.15 * Double(bucket), source: "mockcluster")
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let resp = SuggestResponse(protocolVersion: 1, suggestions: suggestions)
FileHandle.standardOutput.write(try! encoder.encode(resp))
