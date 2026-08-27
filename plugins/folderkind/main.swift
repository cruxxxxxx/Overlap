import Foundation

// Overlap reference suggestion plugin: "Folder & Neighbors".
//
// Reads a SuggestRequest (JSON) on stdin, writes a SuggestResponse (JSON) on
// stdout, exits 0. Pure Foundation — no dependencies, no Vision. It exercises
// the whole contract INCLUDING the library corpus (`wantsLibrary`), standing in
// for the real "embed → cluster → borrow similar files' tags" plugin with a
// trivial similarity: files that share a folder or kind.
//
// The contract IS the JSON, so these structs are redefined here (not shared with
// the app). Keep them in sync with Sources/PluginContract.swift.

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

func parentFolder(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
}

// Decode the request from stdin.
let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
guard let req = try? decoder.decode(SuggestRequest.self, from: input) else {
    FileHandle.standardError.write(Data("folderkind: bad request JSON\n".utf8))
    exit(1)
}

let library = req.library ?? []
var out: [RawSuggestion] = []

for file in req.files {
    let own = Set(file.tags)
    let folder = parentFolder(file.path)

    // 1. parent folder name → strong signal
    if !folder.isEmpty && !own.contains(folder) {
        out.append(RawSuggestion(path: file.path, tag: folder, confidence: 0.9, source: "folderkind"))
    }
    // 2. file kind → weak signal
    if !own.contains(file.kind) {
        out.append(RawSuggestion(path: file.path, tag: file.kind, confidence: 0.6, source: "folderkind"))
    }
    // 3. neighbor tags from the corpus: tags most common among library files
    //    that share this file's folder or kind (the "similar files" stand-in).
    var freq: [String: Int] = [:]
    for item in library where item.path != file.path {
        let sameFolder = parentFolder(item.path) == folder
        let sameKind = item.kind == file.kind
        guard sameFolder || sameKind else { continue }
        for tag in item.tags where !own.contains(tag) { freq[tag, default: 0] += 1 }
    }
    let maxFreq = Double(freq.values.max() ?? 1)
    let neighbors = freq.sorted { $0.value > $1.value }.prefix(5)
    for (tag, count) in neighbors {
        // scale frequency into 0.4…0.7 so real folder/kind signals still rank above
        let conf = 0.4 + 0.3 * (Double(count) / maxFreq)
        out.append(RawSuggestion(path: file.path, tag: tag, confidence: conf, source: "folderkind"))
    }
}

let encoder = JSONEncoder()
let resp = SuggestResponse(protocolVersion: 1, suggestions: out)
FileHandle.standardOutput.write((try? encoder.encode(resp)) ?? Data("{\"protocolVersion\":1,\"suggestions\":[]}".utf8))
