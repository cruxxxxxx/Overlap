import Foundation

/// A remembered pull: which remote collection lands in which local folder.
/// Saved so *Sync now* (and a linked board's refresh) can repeat it.
struct SourceLink: Codable, Identifiable, Hashable {
    var id = UUID()
    let pluginID: String
    var collection: SourceCollection
    var destination: String
    var includeTextAndLinks = true
    var lastSync: Date?
    var boardID: UUID?
}

enum SourceError: LocalizedError {
    case pluginFailed(String)
    case service(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .pluginFailed(let name):
            return "\(name) didn't answer. Check Console for “[plugins]” lines."
        case .service(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}

struct PullOutcome {
    var tags: Set<String> = []
    var added: [URL] = []
    var retagged: [URL] = []
    var skipped = 0
    var error: String?
}

struct PushOutcome {
    var pushed: [URL] = []
    var failed: [(path: String, error: String)] = []
    var error: String?
}

/// Runs source plugins and turns their answers into files. Stateless and free
/// of UI, so it can run detached (and be compiled into a headless test).
enum SourceEngine {
    private static let maxRetries = 5
    private static let pushChunk = 25

    nonisolated static func plugins(disabledIDs: Set<String> = []) -> [DiscoveredPlugin] {
        PluginRegistry.discover()
            .filter { $0.isSource && !disabledIDs.contains($0.id) }
            .sorted { $0.manifest.name < $1.manifest.name }
    }

    // MARK: - One op

    /// Run one op, waiting out rate limits the plugin reports (`retryAfter`).
    nonisolated static func call(_ plugin: DiscoveredPlugin, _ request: SourceRequest,
                                 onProgress: (@Sendable (String) -> Void)? = nil) async -> Result<SourceResponse, SourceError> {
        for _ in 0...maxRetries {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            guard let response = PluginProcess.run(plugin, request: request, as: SourceResponse.self,
                                                   timeoutMs: plugin.manifest.timeoutMs,
                                                   cancellable: true, onProgress: onProgress) else {
                return .failure(Task.isCancelled ? .cancelled : .pluginFailed(plugin.manifest.name))
            }
            if let wait = response.retryAfter, wait > 0 {
                onProgress?("Rate limited — waiting \(Int(wait.rounded(.up)))s…")
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 300) * 1_000_000_000))
                continue
            }
            if let message = response.error {
                return .failure(.service(message))
            }
            return .success(response)
        }
        return .failure(.service("\(plugin.manifest.name) is still rate limited. Try again later."))
    }

    // MARK: - Naming

    /// `<tagPrefix>/<Collection Title>`. A "/" inside the title would nest the tag, so
    /// it becomes a dash.
    nonisolated static func tag(for info: SourceInfo, collectionTitle: String) -> String {
        "\(info.tagPrefix)/\(sanitized(collectionTitle, fallback: "Untitled"))"
    }

    /// `<scope>/<displayName>/` — every collection's default parent folder.
    nonisolated static func providerFolder(scope: URL, info: SourceInfo) -> URL {
        scope.appendingPathComponent(sanitized(info.displayName, fallback: "Source"), isDirectory: true)
    }

    nonisolated static func defaultDestination(scope: URL, info: SourceInfo, collectionTitle: String) -> URL {
        providerFolder(scope: scope, info: info)
            .appendingPathComponent(sanitized(collectionTitle, fallback: "Untitled"), isDirectory: true)
    }

    nonisolated static func sanitized(_ name: String, fallback: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Known files (no index: read origins on demand)

    /// Files under `roots` that already came from `plugin`, by remote id.
    nonisolated static func knownFiles(plugin: String, roots: [URL]) -> [String: URL] {
        var known: [String: URL] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }
            while let url = en.nextObject() as? URL {
                for record in FileOrigin.records(of: url) where record.plugin == plugin {
                    known[record.remoteId] = known[record.remoteId] ?? url
                }
            }
        }
        return known
    }

    // MARK: - Pull

    nonisolated static func pull(_ link: SourceLink, plugin: DiscoveredPlugin, scope: URL,
                                 secrets: [String: String], settings: [String: SettingValue],
                                 onProgress: (@Sendable (String) -> Void)? = nil) async -> PullOutcome {
        var outcome = PullOutcome()
        guard let info = plugin.manifest.source else {
            outcome.error = "\(plugin.manifest.name) is not a source plugin."
            return outcome
        }
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: link.destination, isDirectory: true)
        let staging = stagingRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            outcome.error = error.localizedDescription
            return outcome
        }
        defer {
            try? fm.removeItem(at: staging)
        }

        let tag = tag(for: info, collectionTitle: link.collection.title)
        var known = knownFiles(plugin: plugin.id,
                               roots: [providerFolder(scope: scope, info: info), destination])
        var cursor: String?
        repeat {
            let request = SourceRequest(op: .pull, settings: settings, secrets: secrets,
                                        collection: link.collection.id, cursor: cursor,
                                        since: link.lastSync, stagingDir: staging.path,
                                        knownIds: Array(known.keys))
            switch await call(plugin, request, onProgress: onProgress) {
            case .failure(let error):
                outcome.error = error.localizedDescription
                return outcome
            case .success(let page):
                for item in page.items ?? [] {
                    ingest(item, collectionID: link.collection.id, tag: tag, plugin: plugin.id,
                           staging: staging, into: destination, includeTextAndLinks: link.includeTextAndLinks,
                           known: &known, outcome: &outcome)
                }
                onProgress?("Imported \(outcome.added.count) new from “\(link.collection.title)”…")
                cursor = page.nextCursor
            }
        } while cursor != nil && !Task.isCancelled
        if Task.isCancelled {
            outcome.error = SourceError.cancelled.localizedDescription
        }
        return outcome
    }

    /// One remote item → a tagged local file (or, when it's already here, the
    /// existing file gains this collection's tag and origin).
    nonisolated private static func ingest(_ item: SourceItem, collectionID: String, tag: String, plugin: String,
                                           staging: URL, into destination: URL, includeTextAndLinks: Bool,
                                           known: inout [String: URL], outcome: inout PullOutcome) {
        let record = OriginRecord(plugin: plugin, remoteId: item.remoteId, collection: collectionID,
                                  url: item.url, updatedAt: item.updatedAt)
        outcome.tags.insert(tag)
        if let existing = known[item.remoteId] {
            if adopt(existing, record: record, tag: tag) {
                outcome.retagged.append(existing)
            }
            return
        }
        guard let file = materialize(item, staging: staging, into: destination,
                                     includeTextAndLinks: includeTextAndLinks) else {
            outcome.skipped += 1
            return
        }
        try? TagIO.setTags(TagIO.tags(of: file) + [tag], on: file)
        FileOrigin.add(record, to: file)
        FileOrigin.setWhereFrom([item.url, item.sourceURL].compactMap { $0 }, on: file)
        known[item.remoteId] = file
        outcome.added.append(file)
    }

    // MARK: - Save picked items (browse)

    /// One item chosen while browsing, and the collection it's filed under.
    struct Pick: Sendable {
        let item: SourceItem
        let collection: SourceCollection
    }

    /// The collection loose picks (search results) are filed under.
    nonisolated static func savedCollection() -> SourceCollection {
        SourceCollection(id: "overlap-saved", title: "Saved")
    }

    /// Download only the chosen items. Each lands in its collection's default
    /// folder with that collection's tag; ones already here just gain the tag.
    nonisolated static func save(_ picks: [Pick], plugin: DiscoveredPlugin, scope: URL,
                                 secrets: [String: String], settings: [String: SettingValue],
                                 onProgress: (@Sendable (String) -> Void)? = nil) async -> PullOutcome {
        var outcome = PullOutcome()
        guard let info = plugin.manifest.source else {
            outcome.error = "\(plugin.manifest.name) is not a source plugin."
            return outcome
        }
        let fm = FileManager.default
        let staging = stagingRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: staging)
        }
        var known = knownFiles(plugin: plugin.id, roots: [providerFolder(scope: scope, info: info)])
        let collectionByItem = Dictionary(picks.map { ($0.item.remoteId, $0.collection) },
                                          uniquingKeysWith: { first, _ in first })
        func target(_ remoteId: String) -> (SourceCollection, URL, String) {
            let collection = collectionByItem[remoteId] ?? savedCollection()
            return (collection,
                    defaultDestination(scope: scope, info: info, collectionTitle: collection.title),
                    tag(for: info, collectionTitle: collection.title))
        }

        // Already here: no download, just this collection's tag.
        for pick in picks where known[pick.item.remoteId] != nil {
            let (collection, folder, tag) = target(pick.item.remoteId)
            ingest(pick.item, collectionID: collection.id, tag: tag, plugin: plugin.id, staging: staging,
                   into: folder, includeTextAndLinks: true, known: &known, outcome: &outcome)
        }
        let wanted = picks.map(\.item.remoteId).filter { known[$0] == nil }
        var start = 0
        while start < wanted.count && !Task.isCancelled {
            let chunk = Array(wanted[start..<min(start + pushChunk, wanted.count)])
            start += pushChunk
            let request = SourceRequest(op: .fetch, settings: settings, secrets: secrets,
                                        stagingDir: staging.path, remoteIds: chunk)
            switch await call(plugin, request, onProgress: onProgress) {
            case .failure(let error):
                outcome.error = error.localizedDescription
                return outcome
            case .success(let response):
                for item in response.items ?? [] {
                    let (collection, folder, tag) = target(item.remoteId)
                    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    ingest(item, collectionID: collection.id, tag: tag, plugin: plugin.id, staging: staging,
                           into: folder, includeTextAndLinks: true, known: &known, outcome: &outcome)
                }
            }
            onProgress?("Saved \(outcome.added.count) of \(wanted.count)…")
        }
        return outcome
    }

    /// A file already pulled (maybe for another collection): give it this
    /// collection's tag and origin. True when anything changed.
    nonisolated private static func adopt(_ file: URL, record: OriginRecord, tag: String) -> Bool {
        let hasRecord = FileOrigin.records(of: file).contains {
            $0.plugin == record.plugin && $0.collection == record.collection
        }
        let tags = TagIO.tags(of: file)
        if hasRecord && tags.contains(tag) {
            return false
        }
        if !tags.contains(tag) {
            try? TagIO.setTags(tags + [tag], on: file)
        }
        if !hasRecord {
            FileOrigin.add(record, to: file)
        }
        return true
    }

    /// Turn one remote item into a file in `folder`. Downloaded bytes must sit
    /// inside the staging dir; anything else from the plugin is ignored.
    nonisolated private static func materialize(_ item: SourceItem, staging: URL, into folder: URL,
                                                includeTextAndLinks: Bool) -> URL? {
        let fm = FileManager.default
        let baseName = sanitized(item.filename ?? item.title ?? "", fallback: item.remoteId)
        if let file = item.file {
            let source = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath()
            let stagingPath = staging.standardizedFileURL.resolvingSymlinksInPath().path
            guard source.path.hasPrefix(stagingPath + "/"), fm.fileExists(atPath: source.path) else {
                return nil
            }
            var name = baseName
            if (name as NSString).pathExtension.isEmpty && !source.pathExtension.isEmpty {
                name += "." + source.pathExtension
            }
            let target = uniqueDestination(in: folder, name: name)
            return (try? fm.moveItem(at: source, to: target)) != nil ? target : nil
        }
        guard includeTextAndLinks else {
            return nil
        }
        if let text = item.text, !text.isEmpty {
            let target = uniqueDestination(in: folder, name: withExtension(baseName, "md"))
            return (try? Data(text.utf8).write(to: target)) != nil ? target : nil
        }
        if let link = item.sourceURL ?? item.url {
            let plist: [String: String] = ["URL": link]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                                 format: .xml, options: 0) else {
                return nil
            }
            let target = uniqueDestination(in: folder, name: withExtension(baseName, "webloc"))
            return (try? data.write(to: target)) != nil ? target : nil
        }
        return nil
    }

    nonisolated private static func withExtension(_ name: String, _ ext: String) -> String {
        (name as NSString).pathExtension.lowercased() == ext ? name : name + "." + ext
    }

    // MARK: - Push

    /// Push already privacy-filtered files to one collection. Files the service
    /// already has (origin xattr) are connected by id, not uploaded again.
    nonisolated static func push(_ files: [URL], to collection: SourceCollection, plugin: DiscoveredPlugin,
                                 secrets: [String: String], settings: [String: SettingValue],
                                 onProgress: (@Sendable (String) -> Void)? = nil) async -> PushOutcome {
        var outcome = PushOutcome()
        guard let info = plugin.manifest.source else {
            outcome.error = "\(plugin.manifest.name) is not a source plugin."
            return outcome
        }
        let tag = tag(for: info, collectionTitle: collection.title)
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var start = 0
        while start < files.count {
            let chunk = files[start..<min(start + pushChunk, files.count)]
            start += pushChunk
            let items = chunk.map { url in
                SourcePushItem(path: url.path, title: url.deletingPathExtension().lastPathComponent,
                               remoteId: FileOrigin.remoteId(of: url, plugin: plugin.id))
            }
            let request = SourceRequest(op: .push, settings: settings, secrets: secrets,
                                        collection: collection.id, items: items)
            switch await call(plugin, request, onProgress: onProgress) {
            case .failure(let error):
                outcome.error = error.localizedDescription
                return outcome
            case .success(let response):
                let answered = Set((response.pushed ?? []).map(\.path))
                for item in items where !answered.contains(item.path) {
                    outcome.failed.append((item.path, "Not sent"))
                }
                for result in response.pushed ?? [] {
                    guard let url = byPath[result.path] else {
                        continue
                    }
                    guard let remoteId = result.remoteId, result.error == nil else {
                        outcome.failed.append((result.path, result.error ?? "Not uploaded"))
                        continue
                    }
                    FileOrigin.add(OriginRecord(plugin: plugin.id, remoteId: remoteId,
                                                collection: collection.id, url: result.url,
                                                updatedAt: Date()), to: url)
                    TagIO.addTag(tag, to: [url])
                    outcome.pushed.append(url)
                }
            }
            onProgress?("Sent \(outcome.pushed.count) of \(files.count) to “\(collection.title)”…")
        }
        return outcome
    }

    // MARK: - Files

    nonisolated static func stagingRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/Staging", isDirectory: true)
    }

    nonisolated private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
