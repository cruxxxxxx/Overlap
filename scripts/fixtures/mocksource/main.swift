// mocksource — a fake "source" provider for exercising Overlap's import/push
// flow with no network. The "service" is a folder on disk:
//
//   $MOCKSOURCE_ROOT (default: ./fixture next to this executable)
//     <collection>/            one folder per collection
//       photo.jpg              → image item, remoteId "photo.jpg"
//       note.txt               → text item
//       site.url               → link item (file contents = the URL)
//
// The same filename in two collections is the same remote item, which tests
// the host's cross-collection dedupe. Push copies files into the collection
// folder (or, for a known remoteId, leaves a ".connected" marker).
import Foundation

struct Request: Decodable {
    let op: String
    let settings: [String: Double?]?
    let secrets: [String: String]?
    let collection: String?
    let cursor: String?
    let stagingDir: String?
    let knownIds: [String]?
    let items: [PushItem]?
    let title: String?
    let visibility: String?
    let scope: String?
    let remoteIds: [String]?
    let remoteId: String?
}
struct PushItem: Decodable { let path: String; let title: String; let remoteId: String? }

func emit(_ object: [String: Any]) {
    var out = object
    out["protocolVersion"] = 1
    let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}

let fm = FileManager.default
let root: URL = {
    if let env = ProcessInfo.processInfo.environment["MOCKSOURCE_ROOT"] {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("fixture", isDirectory: true)
}()

guard let req = try? JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile()) else {
    emit(["error": "mocksource: bad request JSON"])
    exit(1)
}

let signedIn = !(req.secrets?["token"] ?? "").isEmpty
if req.op != "status" && !signedIn {
    emit(["error": "Not signed in. Add any token in Connected Services."])
}

func collectionDict(_ dir: URL) -> [String: Any] {
    let count = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    let visibility = fm.fileExists(atPath: dir.appendingPathComponent(".private").path) ? "private" : "public"
    return ["id": dir.lastPathComponent, "title": dir.lastPathComponent, "count": count,
            "writable": true, "visibility": visibility, "url": dir.absoluteString]
}

func collectionDir(_ id: String?) -> URL? {
    guard let id, !id.contains("/"), !id.hasPrefix(".") else {
        return nil
    }
    let dir = root.appendingPathComponent(id, isDirectory: true)
    var isDir: ObjCBool = false
    return fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
}

switch req.op {
case "status":
    emit(["account": ["name": (signedIn ? "Mock User" : NSNull()) as Any, "authenticated": signedIn,
                      "canWrite": signedIn,
                      "browseScopes": [["id": "mine", "label": "Mine", "symbol": "folder"]]]])

case "collections":
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    emit(["collections": dirs.map(collectionDict)])

case "resolve":
    guard let dir = collectionDir(req.collection) else {
        emit(["error": "No folder named “\(req.collection ?? "")”."])
        exit(0)
    }
    emit(["collections": [collectionDict(dir)]])

case "createCollection":
    let title = (req.title ?? "").trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty, !title.contains("/") else {
        emit(["error": "Bad title"])
        exit(0)
    }
    let dir = root.appendingPathComponent(title, isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if req.visibility == "private" {
        fm.createFile(atPath: dir.appendingPathComponent(".private").path, contents: nil)
    }
    emit(["collections": [collectionDict(dir)]])

case "pull":
    guard let dir = collectionDir(req.collection), let staging = req.stagingDir else {
        emit(["error": "Unknown collection"])
        exit(0)
    }
    let pageSize = max(1, Int((req.settings?["pageSize"] ?? nil) ?? 2))
    let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
    let start = Int(req.cursor ?? "0") ?? 0
    let page = names.dropFirst(start).prefix(pageSize)
    var items: [[String: Any]] = []
    for name in page {
        let src = dir.appendingPathComponent(name)
        let ext = src.pathExtension.lowercased()
        var item: [String: Any] = ["remoteId": name, "title": src.deletingPathExtension().lastPathComponent,
                                   "url": "mock://\(dir.lastPathComponent)/\(name)"]
        if req.knownIds?.contains(name) == true {
            item["kind"] = "image"
        } else if ext == "txt" {
            item["kind"] = "text"
            item["text"] = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
        } else if ext == "url" {
            item["kind"] = "link"
            item["sourceURL"] = ((try? String(contentsOf: src, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let dest = URL(fileURLWithPath: staging).appendingPathComponent(UUID().uuidString + "-" + name)
            guard (try? fm.copyItem(at: src, to: dest)) != nil else {
                continue
            }
            item["kind"] = "image"
            item["file"] = dest.path
            item["filename"] = name
        }
        items.append(item)
    }
    let next = start + page.count
    FileHandle.standardError.write(Data("mocksource: page \(start)–\(next) of \(names.count)\n".utf8))
    emit(["items": items, "nextCursor": (next < names.count ? String(next) : NSNull()) as Any])

case "push":
    guard let dir = collectionDir(req.collection) else {
        emit(["error": "Unknown collection"])
        exit(0)
    }
    var pushed: [[String: Any]] = []
    for item in req.items ?? [] {
        let src = URL(fileURLWithPath: item.path)
        if let remoteId = item.remoteId {
            fm.createFile(atPath: dir.appendingPathComponent(".\(remoteId).connected").path, contents: nil)
            pushed.append(["path": item.path, "remoteId": remoteId,
                           "url": "mock://\(dir.lastPathComponent)/\(remoteId)"])
            continue
        }
        let name = src.lastPathComponent
        let dest = dir.appendingPathComponent(name)
        if (try? fm.copyItem(at: src, to: dest)) != nil {
            pushed.append(["path": item.path, "remoteId": name, "url": "mock://\(dir.lastPathComponent)/\(name)"])
        } else {
            pushed.append(["path": item.path, "error": "copy failed"])
        }
    }
    emit(["pushed": pushed])

case "browse":
    if req.scope == "mine" {
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { collectionDir($0.lastPathComponent) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        emit(["collections": dirs.map(collectionDict), "items": []])
    }
    guard let dir = collectionDir(req.collection) else {
        emit(["error": "Unknown collection"])
        exit(0)
    }
    let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    emit(["collections": [], "items": names.map { name in
        ["remoteId": name, "kind": "image", "title": name, "previewURL": dir.appendingPathComponent(name).absoluteString]
    }])

case "fetch":
    guard let staging = req.stagingDir else {
        emit(["error": "No staging"])
        exit(0)
    }
    let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
    var items: [[String: Any]] = []
    for id in req.remoteIds ?? [] {
        guard let src = dirs.map({ $0.appendingPathComponent(id) }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            continue
        }
        let dest = URL(fileURLWithPath: staging).appendingPathComponent(UUID().uuidString + "-" + id)
        if (try? fm.copyItem(at: src, to: dest)) != nil {
            items.append(["remoteId": id, "kind": "image", "file": dest.path, "filename": id])
        }
    }
    emit(["items": items])

case "related":
    let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { collectionDir($0.lastPathComponent) != nil }
    let holding = dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent(req.remoteId ?? "").path) }
    emit(["collections": holding.map(collectionDict)])

case "updateCollection":
    guard let dir = collectionDir(req.collection) else {
        emit(["error": "Unknown collection"])
        exit(0)
    }
    var current = dir
    if let title = req.title, !title.isEmpty, title != dir.lastPathComponent {
        current = root.appendingPathComponent(title, isDirectory: true)
        try? fm.moveItem(at: dir, to: current)
    }
    let marker = current.appendingPathComponent(".private").path
    if req.visibility == "private" {
        fm.createFile(atPath: marker, contents: nil)
    } else if req.visibility != nil {
        try? fm.removeItem(atPath: marker)
    }
    emit(["collections": [collectionDict(current)]])

default:
    emit(["error": "Unknown op \(req.op)"])
}
