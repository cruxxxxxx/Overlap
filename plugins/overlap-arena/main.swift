// overlap-arena — Overlap source plugin for Are.na (REST API v3).
//
// Speaks Overlap's source contract (see Sources/SourceContract.swift): one JSON
// request on stdin with an `op`, one JSON response on stdout. All Are.na
// knowledge lives here; the host only sees collections (channels) and items
// (blocks). Auth is a personal access token from are.na/settings/oauth.
//
// Rate limits are per account per minute (free 120). A 429 inside this
// process is waited out (≤60s, a few times) so a half-done push is never
// re-sent; longer waits come back to the host as `retryAfter` (pull only).
import Foundation
import UniformTypeIdentifiers

let api = URL(string: "https://api.are.na/v3")!
/// v3 search is Premium-only; the older v2 search still finds channels for everyone.
let legacySearch = URL(string: "https://api.are.na/v2/search/channels")!
let site = "https://www.are.na"
let pageSize = 50

// MARK: - Request / response

struct Request: Decodable {
    let op: String
    let settings: [String: Setting]?
    let secrets: [String: String]?
    let collection: String?
    let cursor: String?
    let stagingDir: String?
    let knownIds: [String]?
    let items: [PushItem]?
    let title: String?
    let visibility: String?
    let description: String?
    let scope: String?
    let query: String?
    let remoteIds: [String]?
    let remoteId: String?
}
struct PushItem: Decodable { let path: String; let title: String; let remoteId: String? }
enum Setting: Decodable {
    case number(Double), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = (try? c.decode(Double.self)).map(Setting.number) ?? .other
    }
    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
}

func emit(_ object: [String: Any]) -> Never {
    var out = object
    out["protocolVersion"] = 1
    let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}
func fail(_ message: String) -> Never { emit(["error": message]) }
func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

guard let req = try? JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile()) else {
    fail("overlap-arena: bad request JSON")
}
let token = (req.secrets?["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

// MARK: - HTTP

typealias JSON = [String: Any]

enum APIError: Error {
    case rateLimited(Double)
    case status(Int, String)
    case transport(String)

    var message: String {
        switch self {
        case .rateLimited(let wait):
            return "Are.na rate limit reached; try again in \(Int(wait))s."
        case .status(401, _):
            return "Are.na rejected the token. Paste a new one in Connected Services."
        case .status(403, let body):
            return body.isEmpty ? "Are.na says this isn't allowed. Sending needs a token with write scope." : body
        case .status(404, _):
            return "Not found on Are.na (deleted, private, or a typo?)."
        case .status(let code, let body):
            return "Are.na error \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .transport(let detail):
            return "Couldn't reach Are.na: \(detail)"
        }
    }
}

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.httpAdditionalHeaders = ["User-Agent": "Overlap (macOS; overlap-arena 0.1)"]
    return URLSession(configuration: config)
}()

func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var lastWait = 0.0
    for _ in 0..<3 {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("no HTTP response")
        }
        if http.statusCode == 429 {
            lastWait = retryAfter(http, data)
            guard lastWait <= 60 else {
                break
            }
            log("Rate limited — waiting \(Int(lastWait))s…")
            try? await Task.sleep(nanoseconds: UInt64(lastWait * 1_000_000_000))
            continue
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.status(http.statusCode, errorText(data))
        }
        return (data, http)
    }
    throw APIError.rateLimited(max(lastWait, 60))
}

func retryAfter(_ http: HTTPURLResponse, _ data: Data) -> Double {
    if let header = http.value(forHTTPHeaderField: "Retry-After"), let s = Double(header) {
        return max(1, s)
    }
    if let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
       let error = json["error"] as? JSON, let s = error["retry_after"] as? Double {
        return max(1, s)
    }
    if let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
        return max(1, reset - Date().timeIntervalSince1970)
    }
    return 30
}

func errorText(_ data: Data) -> String {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
        return ""
    }
    if let error = json["error"] as? JSON, let message = error["message"] as? String {
        return message
    }
    if let message = json["error"] as? String ?? json["message"] as? String {
        return message
    }
    if let details = json["details"] as? JSON, let message = details["message"] as? String {
        return message
    }
    return ""
}

func call(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
          base: URL = api) async throws -> JSON {
    let endpoint = path.isEmpty ? base : base.appendingPathComponent(path)
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, _) = try await send(request)
    if data.isEmpty {
        return [:]
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
}

// MARK: - Mapping

func string(_ value: Any?) -> String? {
    switch value {
    case let s as String:
        return s
    case let n as NSNumber:
        return n.stringValue
    default:
        return nil
    }
}

func channelURL(_ channel: JSON) -> String? {
    guard let slug = channel["slug"] as? String else {
        return nil
    }
    let owner = (channel["owner"] as? JSON)?["slug"] as? String
    return owner.map { "\(site)/\($0)/\(slug)" } ?? "\(site)/channel/\(slug)"
}

func collection(_ channel: JSON, me: String?) -> JSON? {
    guard let id = string(channel["id"]) else {
        return nil
    }
    var out: JSON = ["id": id, "title": channel["title"] as? String ?? "Untitled"]
    out["url"] = channelURL(channel)
    out["count"] = (channel["counts"] as? JSON)?["blocks"]
    out["visibility"] = channel["visibility"]
    out["updatedAt"] = channel["updated_at"]
    let owner = channel["owner"] as? JSON
    out["owner"] = owner?["name"]
    out["description"] = (channel["description"] as? JSON)?["plain"] ?? channel["description"] as? String
    if let can = channel["can"] as? JSON, let addTo = can["add_to"] as? Bool {
        out["writable"] = addTo
    } else if let me, let ownerID = string(owner?["id"]) {
        out["writable"] = ownerID == me
    }
    return out
}

/// A channel from the v2 search API, which uses its own field names.
func legacyCollection(_ channel: JSON) -> JSON? {
    guard let id = string(channel["id"]) else {
        return nil
    }
    var out: JSON = ["id": id, "title": channel["title"] as? String ?? "Untitled"]
    if let slug = channel["slug"] as? String {
        out["url"] = (channel["owner_slug"] as? String).map { "\(site)/\($0)/\(slug)" } ?? "\(site)/channel/\(slug)"
    }
    out["count"] = channel["length"]
    out["visibility"] = channel["status"]
    out["updatedAt"] = channel["updated_at"]
    out["owner"] = (channel["user"] as? JSON)?["full_name"]
    return out
}

/// "https://www.are.na/user/my-channel", "my-channel", or "12345" → slug or id.
func channelKey(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.host?.hasSuffix("are.na") == true {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let last = parts.last {
            return last
        }
    }
    return trimmed
}

func blockURL(_ id: String) -> String { "\(site)/block/\(id)" }

// MARK: - Ops

func requireToken() {
    if token.isEmpty {
        fail("Not signed in. Add a personal access token in Connected Services.")
    }
}

func myID() async throws -> String {
    let me = try await call("GET", "me")
    guard let id = string(me["id"]) else {
        throw APIError.transport("no user id in /me")
    }
    return id
}

func opStatus() async -> Never {
    guard !token.isEmpty else {
        emit(["account": ["authenticated": false]])
    }
    do {
        let me = try await call("GET", "me")
        var account: JSON = ["authenticated": true]
        account["name"] = me["name"] ?? me["username"]
        if let slug = me["slug"] as? String {
            account["url"] = "\(site)/\(slug)"
        }
        var scopes: [JSON] = [
            ["id": "feed", "label": "Feed", "symbol": "dot.radiowaves.left.and.right"],
            ["id": "following", "label": "Following", "symbol": "person.2"],
            ["id": "mine", "label": "My Channels", "symbol": "square.stack"],
        ]
        // Searching blocks is a Premium endpoint; everyone can search channels.
        if let tier = me["tier"] as? String, tier == "premium" || tier == "supporter" {
            scopes.append(["id": "search", "label": "Search", "takesQuery": true, "symbol": "magnifyingglass"])
        } else {
            scopes.append(["id": "searchChannels", "label": "Search Channels", "takesQuery": true,
                           "symbol": "magnifyingglass"])
        }
        account["browseScopes"] = scopes
        emit(["account": account])
    } catch let error as APIError {
        if case .status(401, _) = error {
            emit(["account": ["authenticated": false]])
        }
        fail(error.message)
    } catch {
        fail(error.localizedDescription)
    }
}

func opCollections() async throws -> Never {
    requireToken()
    let me = try await myID()
    var out: [JSON] = []
    var page = 1
    while page <= 20 {
        let json = try await call("GET", "users/\(me)/contents",
                                  query: ["type": "Channel", "per": "100", "page": String(page),
                                          "sort": "updated_at_desc"])
        for channel in json["data"] as? [JSON] ?? [] {
            if let c = collection(channel, me: me) {
                out.append(c)
            }
        }
        guard (json["meta"] as? JSON)?["has_more_pages"] as? Bool == true else {
            break
        }
        page += 1
    }
    emit(["collections": out])
}

func opResolve() async throws -> Never {
    let key = channelKey(req.collection ?? "")
    guard !key.isEmpty else {
        fail("Paste a channel link or slug.")
    }
    let me = token.isEmpty ? nil : try? await myID()
    let channel = try await call("GET", "channels/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)")
    guard let c = collection(channel, me: me) else {
        fail("That isn't a channel.")
    }
    emit(["collections": [c]])
}

func opCreateCollection() async throws -> Never {
    requireToken()
    let title = (req.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
        fail("Give the channel a name.")
    }
    var body: JSON = ["title": title]
    if let visibility = req.visibility {
        body["visibility"] = visibility
    }
    if let description = req.description, !description.isEmpty {
        body["description"] = description
    }
    let channel = try await call("POST", "channels", body: body)
    guard let c = collection(channel, me: nil) else {
        fail("Are.na didn't return the new channel.")
    }
    var writable = c
    writable["writable"] = true
    emit(["collections": [writable]])
}

struct Download { let url: URL; let dest: URL }

/// One block → a source item. With `staging`, image/attachment bytes are
/// queued for download into it; without, only a preview URL is given (browse).
func item(_ block: JSON, staging: URL?, known: Set<String> = [], maxBytes: Int = .max,
          downloads: inout [Download]) -> JSON? {
    guard let id = string(block["id"]), let type = block["type"] as? String else {
        return nil
    }
    var item: JSON = ["remoteId": id, "url": blockURL(id)]
    item["title"] = block["title"] as? String
    item["updatedAt"] = block["updated_at"]
    item["description"] = (block["description"] as? JSON)?["plain"]
    item["author"] = (block["user"] as? JSON)?["name"]
    item["sourceURL"] = (block["source"] as? JSON)?["url"] as? String
    let image = block["image"] as? JSON
    item["previewURL"] = ((image?["medium"] as? JSON)?["src"] ?? (image?["small"] as? JSON)?["src"] ?? image?["src"])
    if type == "Link" || type == "Embed", item["sourceURL"] == nil {
        item["sourceURL"] = (block["embed"] as? JSON)?["source_url"] ?? (block["embed"] as? JSON)?["url"]
    }
    let kinds = ["Image": "image", "Attachment": "file", "Text": "text", "Link": "link", "Embed": "embed"]
    guard let kind = kinds[type] else {
        return nil   // channels inside channels, blocks still processing
    }
    item["kind"] = kind
    if type == "Text" {
        item["text"] = (block["content"] as? JSON)?["markdown"] as? String ?? ""
        item["previewText"] = (block["content"] as? JSON)?["plain"]
    }
    if type == "Embed", let html = (block["embed"] as? JSON)?["html"] as? String, html.contains("<iframe") {
        item["embedHTML"] = html
    }
    guard let staging, !known.contains(id) else {
        return item
    }
    switch type {
    case "Image":
        guard let src = image?["src"] as? String, let url = URL(string: src) else {
            return nil
        }
        let name = image?["filename"] as? String ?? url.lastPathComponent
        let dest = staging.appendingPathComponent("\(id)-\(safeName(name))")
        downloads.append(Download(url: url, dest: dest))
        item["file"] = dest.path
        item["filename"] = (item["title"] as? String).map { withExtension($0, of: name) } ?? name
    case "Attachment":
        guard let attachment = block["attachment"] as? JSON, let link = attachment["url"] as? String,
              let url = URL(string: link) else {
            return nil
        }
        if let size = attachment["file_size"] as? Int, size > maxBytes {
            log("Skipping \(attachment["filename"] ?? id): \(size / 1_048_576) MB")
            return nil
        }
        let name = attachment["filename"] as? String ?? url.lastPathComponent
        let dest = staging.appendingPathComponent("\(id)-\(safeName(name))")
        downloads.append(Download(url: url, dest: dest))
        item["file"] = dest.path
        item["filename"] = name
    case "Link", "Embed":
        // Saved as its picture (a video's still, a page's screenshot); the
        // link itself travels in sourceURL. No picture → the host writes a link file.
        guard let src = image?["src"] as? String, let url = URL(string: src) else {
            break
        }
        let name = image?["filename"] as? String ?? url.lastPathComponent
        let dest = staging.appendingPathComponent("\(id)-\(safeName(name))")
        downloads.append(Download(url: url, dest: dest))
        item["file"] = dest.path
        item["filename"] = (item["title"] as? String).map { withExtension($0, of: name) } ?? name
    default:
        break
    }
    return item
}

/// Download, then drop items whose bytes didn't arrive.
func finishDownloads(_ items: [JSON], _ downloads: [Download]) async -> [JSON] {
    let failed = await fetch(downloads)
    return items.compactMap { item in
        guard let file = item["file"] as? String, failed.contains(file) else {
            return item
        }
        // A link or video whose picture didn't arrive is still worth a link file.
        guard item["kind"] as? String == "link" || item["kind"] as? String == "embed" else {
            return nil
        }
        var linkOnly = item
        linkOnly["file"] = nil
        linkOnly["filename"] = nil
        return linkOnly
    }
}

func maxAttachmentBytes() -> Int { Int((req.settings?["maxFileMB"]?.number ?? 100) * 1_048_576) }

func opPull() async throws -> Never {
    guard let key = req.collection, let stagingDir = req.stagingDir else {
        fail("No channel given.")
    }
    let page = Int(req.cursor ?? "1") ?? 1
    let json = try await call("GET", "channels/\(key)/contents",
                              query: ["page": String(page), "per": String(pageSize), "sort": "position_desc"])
    let staging = URL(fileURLWithPath: stagingDir, isDirectory: true)
    let known = Set(req.knownIds ?? [])
    var downloads: [Download] = []
    let items = (json["data"] as? [JSON] ?? []).compactMap {
        item($0, staging: staging, known: known, maxBytes: maxAttachmentBytes(), downloads: &downloads)
    }
    let meta = json["meta"] as? JSON
    let total = meta?["total_count"] as? Int
    log("Page \(page)\(total.map { " of \(Int(ceil(Double($0) / Double(pageSize))))" } ?? "") from Are.na")
    var out: JSON = ["items": await finishDownloads(items, downloads)]
    if meta?["has_more_pages"] as? Bool == true {
        out["nextCursor"] = String(page + 1)
    }
    emit(out)
}

func opFetch() async throws -> Never {
    guard let stagingDir = req.stagingDir else {
        fail("No staging folder.")
    }
    let staging = URL(fileURLWithPath: stagingDir, isDirectory: true)
    var items: [JSON] = []
    var downloads: [Download] = []
    for id in req.remoteIds ?? [] {
        let block = try await call("GET", "blocks/\(id)")
        if let mapped = item(block, staging: staging, maxBytes: maxAttachmentBytes(), downloads: &downloads) {
            items.append(mapped)
        }
    }
    emit(["items": await finishDownloads(items, downloads)])
}

/// Split a mixed list (channel contents, search) into channels and blocks.
func split(_ data: [JSON], me: String?) -> (collections: [JSON], items: [JSON]) {
    var collections: [JSON] = []
    var items: [JSON] = []
    var none: [Download] = []
    for entry in data {
        if entry["type"] as? String == "Channel" {
            if let c = collection(entry, me: me) {
                collections.append(c)
            }
        } else if let mapped = item(entry, staging: nil, downloads: &none) {
            items.append(mapped)
        }
    }
    return (collections, items)
}

func pageQuery(_ extra: [String: String] = [:]) -> (page: Int, query: [String: String]) {
    let page = Int(req.cursor ?? "1") ?? 1
    return (page, extra.merging(["page": String(page), "per": String(pageSize)]) { a, _ in a })
}

func emitPage(collections: [JSON], items: [JSON], next: String?) -> Never {
    var out: JSON = ["collections": collections, "items": items]
    if let next {
        out["nextCursor"] = next
    }
    emit(out)
}

func nextPage(_ json: JSON, _ page: Int) -> String? {
    (json["meta"] as? JSON)?["has_more_pages"] as? Bool == true ? String(page + 1) : nil
}

func opBrowse() async throws -> Never {
    let scope = req.scope ?? "collection"
    if scope != "collection" && scope != "searchChannels" {
        requireToken()
    }
    let me = token.isEmpty ? nil : try? await myID()
    switch scope {
    case "feed":
        var query = ["limit": String(pageSize)]
        if let cursor = req.cursor {
            query["next"] = cursor
        }
        let json = try await call("GET", "me/feed", query: query)
        var collections: [JSON] = []
        var items: [JSON] = []
        var seenChannels = Set<String>()
        var none: [Download] = []
        for activity in json["data"] as? [JSON] ?? [] {
            let subject = activity["item"] as? JSON ?? [:]
            if subject["type"] as? String == "Channel" {
                if let c = collection(subject, me: me), let id = c["id"] as? String, seenChannels.insert(id).inserted {
                    collections.append(c)
                }
            } else if var mapped = item(subject, staging: nil, downloads: &none) {
                if let target = activity["target"] as? JSON, target["type"] as? String == "Channel" {
                    mapped["via"] = collection(target, me: me)
                }
                items.append(mapped)
            }
        }
        let meta = json["meta"] as? JSON
        emitPage(collections: collections, items: items,
                 next: meta?["has_more"] as? Bool == true ? meta?["next_cursor"] as? String : nil)
    case "following":
        let (page, query) = pageQuery(["type": "Channel"])
        let json = try await call("GET", "users/\(me ?? "")/following", query: query)
        let channels = (json["data"] as? [JSON] ?? []).compactMap { collection($0, me: me) }
        emitPage(collections: channels, items: [], next: nextPage(json, page))
    case "mine":
        let (page, query) = pageQuery(["type": "Channel", "sort": "updated_at_desc"])
        let json = try await call("GET", "users/\(me ?? "")/contents", query: query)
        let channels = (json["data"] as? [JSON] ?? []).compactMap { collection($0, me: me) }
        emitPage(collections: channels, items: [], next: nextPage(json, page))
    case "search":
        let text = (req.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            emitPage(collections: [], items: [], next: nil)
        }
        let (page, query) = pageQuery(["query": text])
        let json = try await call("GET", "search", query: query)
        let (collections, items) = split(json["data"] as? [JSON] ?? [], me: me)
        emitPage(collections: collections, items: items, next: nextPage(json, page))
    case "searchChannels":
        let text = (req.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            emitPage(collections: [], items: [], next: nil)
        }
        let page = Int(req.cursor ?? "1") ?? 1
        let json = try await call("GET", "", query: ["q": text, "page": String(page), "per": String(pageSize)],
                                  base: legacySearch)
        let channels = (json["channels"] as? [JSON] ?? []).compactMap(legacyCollection)
        let pages = json["total_pages"] as? Int ?? page
        emitPage(collections: channels, items: [], next: page < pages ? String(page + 1) : nil)
    default:
        guard let key = req.collection else {
            fail("No channel given.")
        }
        let (page, query) = pageQuery(["sort": "position_desc"])
        let json = try await call("GET", "channels/\(key)/contents", query: query)
        let (collections, items) = split(json["data"] as? [JSON] ?? [], me: me)
        emitPage(collections: collections, items: items, next: nextPage(json, page))
    }
}

/// Channels a block is in, or (no block) the channel owner's other channels.
func opRelated() async throws -> Never {
    let me = token.isEmpty ? nil : try? await myID()
    if let block = req.remoteId {
        let json = try await call("GET", "blocks/\(block)/connections", query: ["per": "50"])
        emit(["collections": (json["data"] as? [JSON] ?? []).compactMap { collection($0, me: me) }])
    }
    guard let key = req.collection else {
        fail("Nothing to relate.")
    }
    let channel = try await call("GET", "channels/\(key)")
    guard let owner = channel["owner"] as? JSON, let ownerID = string(owner["id"]) else {
        emit(["collections": []])
    }
    let base = owner["type"] as? String == "Group" ? "groups" : "users"
    let path = base == "groups" ? "groups/\(ownerID)/contents" : "users/\(ownerID)/contents"
    let json = try await call("GET", path, query: ["type": "Channel", "per": "50", "sort": "updated_at_desc"])
    let channels = (json["data"] as? [JSON] ?? []).compactMap { collection($0, me: me) }
        .filter { $0["id"] as? String != string(channel["id"]) }
    emit(["collections": channels])
}

func opUpdateCollection() async throws -> Never {
    requireToken()
    guard let key = req.collection else {
        fail("No channel given.")
    }
    var body: JSON = [:]
    if let title = req.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        body["title"] = title
    }
    if let visibility = req.visibility {
        body["visibility"] = visibility
    }
    if let description = req.description {
        body["description"] = description
    }
    guard !body.isEmpty else {
        fail("Nothing to change.")
    }
    let me = try? await myID()
    let channel = try await call("PUT", "channels/\(key)", body: body)
    guard let c = collection(channel, me: me) else {
        fail("Are.na didn't return the channel.")
    }
    emit(["collections": [c]])
}

/// Download in parallel (4 at a time). Returns the destination paths that failed.
func fetch(_ downloads: [Download]) async -> Set<String> {
    var failed = Set<String>()
    var index = 0
    while index < downloads.count {
        let batch = downloads[index..<min(index + 4, downloads.count)]
        index += 4
        await withTaskGroup(of: String?.self) { group in
            for download in batch {
                group.addTask {
                    do {
                        let (temp, response) = try await session.download(from: download.url)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            return download.dest.path
                        }
                        try FileManager.default.moveItem(at: temp, to: download.dest)
                        return nil
                    } catch {
                        return download.dest.path
                    }
                }
            }
            for await result in group {
                if let path = result {
                    failed.insert(path)
                }
            }
        }
    }
    return failed
}

func safeName(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return cleaned.isEmpty ? "file" : String(cleaned.suffix(120))
}

/// Block titles usually lack an extension; borrow the file's.
func withExtension(_ title: String, of filename: String) -> String {
    let ext = (filename as NSString).pathExtension
    guard !ext.isEmpty, (title as NSString).pathExtension.lowercased() != ext.lowercased() else {
        return title
    }
    return "\(title).\(ext)"
}

func contentType(_ url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
}

func opPush() async throws -> Never {
    requireToken()
    guard let channel = req.collection else {
        fail("No channel given.")
    }
    let items = req.items ?? []
    var results: [JSON] = []

    // Already on Are.na: connect the existing block.
    var uploads: [PushItem] = []
    for item in items {
        guard let remoteId = item.remoteId, let blockID = Int(remoteId) else {
            uploads.append(item)
            continue
        }
        do {
            _ = try await call("POST", "connections",
                               body: ["connectable_id": blockID, "connectable_type": "Block",
                                      "channel_ids": [channel]])
            results.append(["path": item.path, "remoteId": remoteId, "url": blockURL(remoteId)])
        } catch let error as APIError {
            if case .status(422, _) = error {
                // Already connected to this channel: that's the outcome we wanted.
                results.append(["path": item.path, "remoteId": remoteId, "url": blockURL(remoteId)])
            } else {
                results.append(["path": item.path, "error": error.message])
            }
        }
    }

    guard !uploads.isEmpty else {
        emit(["pushed": results])
    }
    // New files: presign (one call for the chunk), PUT to S3, create blocks.
    let files = uploads.map { URL(fileURLWithPath: $0.path) }
    let presign: JSON
    do {
        presign = try await call("POST", "uploads/presign", body: [
            "files": files.map { ["filename": $0.lastPathComponent, "content_type": contentType($0)] },
        ])
    } catch let error as APIError {
        for item in uploads {
            results.append(["path": item.path, "error": error.message])
        }
        emit(["pushed": results])
    }
    let slots = presign["files"] as? [JSON] ?? []
    for (i, item) in uploads.enumerated() {
        guard i < slots.count, let uploadLink = slots[i]["upload_url"] as? String,
              let uploadURL = URL(string: uploadLink), let key = slots[i]["key"] as? String else {
            results.append(["path": item.path, "error": "Are.na didn't give an upload slot"])
            continue
        }
        let type = slots[i]["content_type"] as? String ?? contentType(files[i])
        do {
            var put = URLRequest(url: uploadURL)
            put.httpMethod = "PUT"
            put.setValue(type, forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.upload(for: put, fromFile: files[i])
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                results.append(["path": item.path, "error": "Upload failed"])
                continue
            }
            let block = try await call("POST", "blocks", body: [
                "value": "https://s3.amazonaws.com/arena_images-temp/\(key)",
                "title": item.title,
                "channel_ids": [channel],
            ])
            guard let id = string(block["id"]) else {
                results.append(["path": item.path, "error": "Are.na didn't return the block"])
                continue
            }
            results.append(["path": item.path, "remoteId": id, "url": blockURL(id)])
            log("Sent \(results.count) of \(items.count)")
        } catch let error as APIError {
            results.append(["path": item.path, "error": error.message])
            if case .rateLimited = error {
                break   // the rest would fail the same way; host reports them as not sent
            }
        } catch {
            results.append(["path": item.path, "error": error.localizedDescription])
        }
    }
    emit(["pushed": results])
}

// MARK: - Main

do {
    switch req.op {
    case "status":
        await opStatus()
    case "collections":
        try await opCollections()
    case "resolve":
        try await opResolve()
    case "createCollection":
        try await opCreateCollection()
    case "pull":
        try await opPull()
    case "push":
        try await opPush()
    case "fetch":
        try await opFetch()
    case "browse":
        try await opBrowse()
    case "related":
        try await opRelated()
    case "updateCollection":
        try await opUpdateCollection()
    default:
        fail("overlap-arena: unknown op \(req.op)")
    }
} catch let error as APIError {
    if case .rateLimited(let wait) = error, req.op != "push" {
        emit(["retryAfter": wait])
    }
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}
