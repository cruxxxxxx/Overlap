import Combine
import Foundation

/// A sheet the Sources window should open (set from menus and boards).
enum SourceRoute: Identifiable {
    case importFrom(pluginID: String)
    case send(pluginID: String, urls: [URL], label: String)
    case linkBoard(pluginID: String, boardID: UUID, boardName: String)
    case publishBoard(pluginID: String, boardID: UUID, boardName: String, urls: [URL])
    case editCollection(linkID: UUID)

    var id: String {
        switch self {
        case .importFrom(let pluginID):
            return "import-\(pluginID)"
        case .send(let pluginID, let urls, _):
            return "send-\(pluginID)-\(urls.count)"
        case .linkBoard(let pluginID, let boardID, _):
            return "link-\(pluginID)-\(boardID)"
        case .publishBoard(let pluginID, let boardID, _, _):
            return "publish-\(pluginID)-\(boardID)"
        case .editCollection(let linkID):
            return "edit-\(linkID)"
        }
    }
}

/// App-side state for source plugins: credentials (keychain), remembered pulls
/// (`Sources/links.json`), the running job and its progress. The engine does
/// the work off-main; this hands its results to `TagStore`.
@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var plugins: [DiscoveredPlugin] = []
    @Published private(set) var links: [SourceLink] = []
    @Published private(set) var accounts: [String: SourceAccount] = [:]
    /// Live status line of the running job; nil when idle.
    @Published private(set) var activity: String?
    @Published private(set) var busy = false
    /// Outcome of the last job, for the Sources window.
    @Published var lastMessage: String?
    @Published var lastError: String?
    @Published var route: SourceRoute?
    /// Where an opening (or open) browser window should go.
    @Published var browseTarget: BrowseTarget?

    struct BrowseTarget: Equatable {
        let pluginID: String
        let collection: SourceCollection?
        let serial: Int
    }

    func requestBrowse(_ pluginID: String, collection: SourceCollection? = nil) {
        browseTarget = BrowseTarget(pluginID: pluginID, collection: collection,
                                    serial: (browseTarget?.serial ?? 0) + 1)
    }
    /// Bumped when a pull finishes, so a linked board window can fold the
    /// collection's files in.
    @Published private(set) var finishedPull: FinishedPull?

    struct FinishedPull: Equatable {
        let linkID: UUID
        let serial: Int
    }

    private weak var tags: TagStore?
    private var job: Task<Void, Never>?
    private var pluginToggles: AnyCancellable?

    func attach(to tags: TagStore) {
        guard self.tags == nil else {
            return
        }
        self.tags = tags
        loadLinks()
        reloadPlugins()
        tags.queueExclusions = { [weak self] in self?.managedFolders() ?? [] }
        tags.scanQueue()
        // The Plugins menu can turn a source off; drop it from the Sources menu.
        pluginToggles = tags.$disabledPluginIDs.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reloadPlugins() }
        }
    }

    func reloadPlugins() {
        let disabled = tags?.disabledPluginIDs ?? []
        plugins = SourceEngine.plugins(disabledIDs: disabled)
    }

    /// Every provider folder in the library plus each synced collection's
    /// destination — kept tagged by sync, so they stay out of the queue.
    func managedFolders() -> [URL] {
        guard let scope = tags?.scopeURL else {
            return []
        }
        let providers = plugins.compactMap { plugin in
            plugin.manifest.source.map { SourceEngine.providerFolder(scope: scope, info: $0) }
        }
        return providers + links.map { URL(fileURLWithPath: $0.destination, isDirectory: true) }
    }

    func plugin(_ id: String) -> DiscoveredPlugin? {
        plugins.first { $0.id == id }
    }

    // MARK: - Credentials

    private func secretAccount(_ plugin: DiscoveredPlugin, _ key: String) -> String {
        "\(plugin.id).\(key)"
    }

    func hasSecret(_ plugin: DiscoveredPlugin, _ key: String) -> Bool {
        Keychain.read(secretAccount(plugin, key), service: Keychain.sourcesService) != nil
    }

    func setSecret(_ value: String, plugin: DiscoveredPlugin, key: String) {
        let account = secretAccount(plugin, key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account, service: Keychain.sourcesService)
        } else {
            Keychain.write(Data(trimmed.utf8), account: account, service: Keychain.sourcesService)
        }
        accounts[plugin.id] = nil
        Task {
            await checkAccount(plugin)
        }
    }

    private func secrets(for plugin: DiscoveredPlugin) -> [String: String] {
        var out: [String: String] = [:]
        for secret in plugin.manifest.secrets ?? [] {
            if let data = Keychain.read(secretAccount(plugin, secret.key), service: Keychain.sourcesService),
               let value = String(data: data, encoding: .utf8) {
                out[secret.key] = value
            }
        }
        return out
    }

    private func settings(for plugin: DiscoveredPlugin) -> [String: SettingValue] {
        TagStore.effectiveSettings(for: plugin, stored: tags?.pluginSettings ?? [:]) ?? [:]
    }

    private func request(_ op: SourceOp, _ plugin: DiscoveredPlugin) -> SourceRequest {
        SourceRequest(op: op, settings: settings(for: plugin), secrets: secrets(for: plugin))
    }

    // MARK: - Quick calls (no job)

    func checkAccount(_ plugin: DiscoveredPlugin) async {
        let req = request(.status, plugin)
        let result = await Task.detached { await SourceEngine.call(plugin, req) }.value
        switch result {
        case .success(let response):
            accounts[plugin.id] = response.account ?? SourceAccount(authenticated: false)
        case .failure:
            accounts[plugin.id] = SourceAccount(authenticated: false)
        }
    }

    func collections(_ plugin: DiscoveredPlugin) async -> Result<[SourceCollection], SourceError> {
        let req = request(.collections, plugin)
        return await Task.detached { await SourceEngine.call(plugin, req) }.value.map { $0.collections ?? [] }
    }

    /// A collection the user pasted (URL, slug or id) — e.g. someone else's.
    func resolve(_ text: String, plugin: DiscoveredPlugin) async -> Result<SourceCollection, SourceError> {
        var req = request(.resolve, plugin)
        req.collection = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await Task.detached { await SourceEngine.call(plugin, req) }.value
        return result.flatMap { response in
            guard let first = response.collections?.first else {
                return .failure(.service("Nothing found for “\(text)”."))
            }
            return .success(first)
        }
    }

    func createCollection(_ title: String, visibility: String?, description: String? = nil,
                          plugin: DiscoveredPlugin) async -> Result<SourceCollection, SourceError> {
        var req = request(.createCollection, plugin)
        req.title = title
        req.visibility = visibility
        req.description = description
        let result = await Task.detached { await SourceEngine.call(plugin, req) }.value
        return result.flatMap { response in
            guard let created = response.collections?.first else {
                return .failure(.service("\(plugin.manifest.name) didn't return the new \(plugin.manifest.source?.noun ?? "collection")."))
            }
            return .success(created)
        }
    }

    /// Rename, describe or change the visibility of a remote collection. A
    /// rename also renames its tag on every local file, so membership holds.
    func updateCollection(_ link: SourceLink, title: String?, description: String?,
                          visibility: String?) async -> Result<SourceCollection, SourceError> {
        guard let plugin = plugin(link.pluginID), let info = plugin.manifest.source else {
            return .failure(.service("The plugin for “\(link.collection.title)” isn't installed or is turned off."))
        }
        var req = request(.updateCollection, plugin)
        req.collection = link.collection.id
        req.title = title
        req.description = description
        req.visibility = visibility
        let result = await Task.detached { await SourceEngine.call(plugin, req) }.value
        guard case .success(let response) = result, let updated = response.collections?.first else {
            if case .failure(let error) = result {
                return .failure(error)
            }
            return .failure(.service("\(info.displayName) didn't return the \(info.noun)."))
        }
        let oldTag = SourceEngine.tag(for: info, collectionTitle: link.collection.title)
        let newTag = SourceEngine.tag(for: info, collectionTitle: updated.title)
        if oldTag != newTag {
            tags?.renameTagEverywhere(oldTag, to: newTag)
        }
        for i in links.indices where links[i].pluginID == link.pluginID && links[i].collection.id == link.collection.id {
            links[i].collection = updated
        }
        saveLinks()
        return .success(updated)
    }

    // MARK: - Browse

    func browse(_ plugin: DiscoveredPlugin, scope: String, collection: String? = nil, query: String? = nil,
                cursor: String? = nil) async -> Result<SourceResponse, SourceError> {
        var req = request(.browse, plugin)
        req.scope = scope
        req.collection = collection
        req.query = query
        req.cursor = cursor
        return await Task.detached { await SourceEngine.call(plugin, req) }.value
    }

    /// Collections an item is in, or (no item) the collection owner's others.
    func related(_ plugin: DiscoveredPlugin, remoteId: String? = nil,
                 collection: String? = nil) async -> Result<[SourceCollection], SourceError> {
        var req = request(.related, plugin)
        req.remoteId = remoteId
        req.collection = collection
        return await Task.detached { await SourceEngine.call(plugin, req) }.value.map { $0.collections ?? [] }
    }

    /// Download only the picked items into the library. `done` gets the local
    /// files (new and already-here), e.g. to put them on a board.
    func save(_ picks: [SourceEngine.Pick], plugin: DiscoveredPlugin,
              then done: (@MainActor ([URL]) -> Void)? = nil) {
        guard !busy, let scope = tags?.scopeURL, !picks.isEmpty else {
            return
        }
        let secrets = secrets(for: plugin), settings = settings(for: plugin)
        start("Saving \(picks.count) from \(plugin.manifest.source?.displayName ?? plugin.manifest.name)…")
        job = Task { [weak self] in
            let outcome = await Task.detached {
                await SourceEngine.save(picks, plugin: plugin, scope: scope, secrets: secrets,
                                        settings: settings) { line in
                    Task { @MainActor in self?.activity = line }
                }
            }.value
            guard let self else {
                return
            }
            let files = outcome.added + outcome.retagged
            self.tags?.adoptSourceFiles(files, tags: Array(outcome.tags))
            var message = "Saved \(outcome.added.count) new"
            if !outcome.retagged.isEmpty {
                message += ", \(outcome.retagged.count) already here"
            }
            self.finish(error: outcome.error, message: message + ".")
            done?(files)
        }
    }

    /// Save picked items and wait for them: the local file of every pick that
    /// made it, by remote id. Runs alongside any sync rather than waiting.
    func saveNow(_ picks: [SourceEngine.Pick], plugin: DiscoveredPlugin,
                 tagCollections: Bool) async -> [String: URL] {
        guard let scope = tags?.scopeURL, !picks.isEmpty else {
            return [:]
        }
        let secrets = secrets(for: plugin), settings = settings(for: plugin)
        let ownsStatus = !busy
        if ownsStatus {
            start("Saving \(picks.count) from \(plugin.manifest.source?.displayName ?? plugin.manifest.name)…")
        }
        let outcome = await Task.detached {
            await SourceEngine.save(picks, plugin: plugin, scope: scope, secrets: secrets,
                                    settings: settings, tagCollections: tagCollections) { line in
                Task { @MainActor [weak self] in
                    if ownsStatus {
                        self?.activity = line
                    }
                }
            }
        }.value
        tags?.adoptSourceFiles(Array(outcome.files.values), tags: Array(outcome.tags))
        if ownsStatus {
            finish(error: outcome.error, message: "Saved \(outcome.files.count) to the library.")
        } else if let error = outcome.error {
            lastError = error
        }
        return outcome.files
    }

    /// Whether picks saved with another tag also get their collection's tag:
    /// the plugin's `tagSavedWithCollection` setting (off unless declared on).
    func tagsSavedWithCollection(_ plugin: DiscoveredPlugin) -> Bool {
        if case .bool(let on)? = settings(for: plugin)["tagSavedWithCollection"] {
            return on
        }
        return false
    }

    /// Remote ids already in the library (any collection), for "saved" badges.
    func savedRemoteIds(_ plugin: DiscoveredPlugin) async -> Set<String> {
        guard let info = plugin.manifest.source, let scope = tags?.scopeURL else {
            return []
        }
        let root = SourceEngine.providerFolder(scope: scope, info: info)
        let id = plugin.id
        return await Task.detached {
            Set(SourceEngine.knownFiles(plugin: id, roots: [root]).keys)
        }.value
    }

    // MARK: - Publish a board

    /// New collection from a board: create it, link the board, send its files.
    func publishBoard(_ urls: [URL], boardID: UUID, title: String, visibility: String?,
                      description: String?, plugin: DiscoveredPlugin) async -> SourceError? {
        let allowed = shareable(urls).allowed
        switch await createCollection(title, visibility: visibility, description: description, plugin: plugin) {
        case .failure(let error):
            return error
        case .success(let collection):
            guard let destination = defaultDestination(for: collection, plugin: plugin) else {
                return .service("No library folder.")
            }
            for i in links.indices where links[i].boardID == boardID {
                links[i].boardID = nil
            }
            upsert(SourceLink(pluginID: plugin.id, collection: collection, destination: destination.path,
                              lastSync: Date(), boardID: boardID))
            if !allowed.isEmpty {
                push(allowed, to: collection, plugin: plugin)
            }
            return nil
        }
    }

    // MARK: - Pull

    func defaultDestination(for collection: SourceCollection, plugin: DiscoveredPlugin) -> URL? {
        guard let info = plugin.manifest.source, let scope = tags?.scopeURL else {
            return nil
        }
        return SourceEngine.defaultDestination(scope: scope, info: info, collectionTitle: collection.title)
    }

    func link(for collection: SourceCollection, plugin: DiscoveredPlugin) -> SourceLink? {
        links.first { $0.pluginID == plugin.id && $0.collection.id == collection.id }
    }

    /// Remember (or update) the pull, then run it.
    func importCollection(_ collection: SourceCollection, plugin: DiscoveredPlugin,
                          destination: URL, includeTextAndLinks: Bool, boardID: UUID? = nil) {
        var link = link(for: collection, plugin: plugin)
            ?? SourceLink(pluginID: plugin.id, collection: collection, destination: destination.path)
        link.collection = collection
        link.destination = destination.path
        link.includeTextAndLinks = includeTextAndLinks
        if let boardID {
            // One board ↔ one collection: move the board off any older link.
            for i in links.indices where links[i].boardID == boardID {
                links[i].boardID = nil
            }
            link.boardID = boardID
        }
        upsert(link)
        sync(link)
    }

    func sync(_ link: SourceLink, then done: (@MainActor (PullOutcome) -> Void)? = nil) {
        guard !busy, let plugin = plugin(link.pluginID), let scope = tags?.scopeURL,
              let info = plugin.manifest.source else {
            if plugin(link.pluginID) == nil {
                lastError = "The plugin for “\(link.collection.title)” isn't installed or is turned off."
            }
            return
        }
        let secrets = secrets(for: plugin), settings = settings(for: plugin)
        let tag = SourceEngine.tag(for: info, collectionTitle: link.collection.title)
        start("Syncing “\(link.collection.title)”…")
        job = Task { [weak self] in
            let outcome = await Task.detached {
                await SourceEngine.pull(link, plugin: plugin, scope: scope, secrets: secrets,
                                        settings: settings) { line in
                    Task { @MainActor in self?.activity = line }
                }
            }.value
            guard let self else {
                return
            }
            self.tags?.adoptSourceFiles(outcome.added + outcome.retagged, tags: [tag])
            if outcome.error == nil {
                var updated = link
                updated.lastSync = Date()
                self.upsert(updated)
            }
            self.finish(error: outcome.error,
                        message: self.pullSummary(outcome, title: link.collection.title))
            self.finishedPull = FinishedPull(linkID: link.id, serial: (self.finishedPull?.serial ?? 0) + 1)
            done?(outcome)
        }
    }

    private func pullSummary(_ outcome: PullOutcome, title: String) -> String {
        var parts = ["\(outcome.added.count) new"]
        if !outcome.retagged.isEmpty {
            parts.append("\(outcome.retagged.count) already here, tagged")
        }
        if outcome.skipped > 0 {
            parts.append("\(outcome.skipped) skipped")
        }
        return "“\(title)”: " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Push

    /// The files that may be sent, and how many were held back for privacy.
    func shareable(_ urls: [URL]) -> (allowed: [URL], dropped: Int) {
        tags?.shareableForSource(urls) ?? ([], urls.count)
    }

    func push(_ urls: [URL], to collection: SourceCollection, plugin: DiscoveredPlugin,
              then done: (@MainActor (PushOutcome) -> Void)? = nil) {
        guard !busy, let info = plugin.manifest.source else {
            return
        }
        // Gate again at the last moment: the caller's list may predate a tag change.
        let allowed = shareable(urls).allowed
        guard !allowed.isEmpty else {
            lastError = "Nothing to send: hidden and vault files never leave this Mac."
            return
        }
        let secrets = secrets(for: plugin), settings = settings(for: plugin)
        let tag = SourceEngine.tag(for: info, collectionTitle: collection.title)
        start("Sending \(allowed.count) to “\(collection.title)”…")
        job = Task { [weak self] in
            let outcome = await Task.detached {
                await SourceEngine.push(allowed, to: collection, plugin: plugin, secrets: secrets,
                                        settings: settings) { line in
                    Task { @MainActor in self?.activity = line }
                }
            }.value
            guard let self else {
                return
            }
            self.tags?.adoptSourceFiles(outcome.pushed, tags: [tag])
            var message = "Sent \(outcome.pushed.count) to “\(collection.title)”."
            if !outcome.failed.isEmpty {
                message += " \(outcome.failed.count) failed: \(outcome.failed.first?.error ?? "")"
            }
            self.finish(error: outcome.error, message: message)
            done?(outcome)
        }
    }

    // MARK: - Job lifecycle

    func cancel() {
        job?.cancel()
    }

    private func start(_ status: String) {
        busy = true
        activity = status
        lastError = nil
        lastMessage = nil
    }

    private func finish(error: String?, message: String) {
        busy = false
        activity = nil
        job = nil
        lastError = error
        lastMessage = message
    }

    // MARK: - Links

    func removeLink(_ link: SourceLink) {
        links.removeAll { $0.id == link.id }
        saveLinks()
    }

    func setBoard(_ boardID: UUID?, for link: SourceLink) {
        guard let i = links.firstIndex(where: { $0.id == link.id }) else {
            return
        }
        links[i].boardID = boardID
        saveLinks()
    }

    func link(forBoard boardID: UUID) -> SourceLink? {
        links.first { $0.boardID == boardID }
    }

    func link(id: UUID) -> SourceLink? {
        links.first { $0.id == id }
    }

    /// The local files that belong to a link's collection: its tag is the
    /// membership record (pulled, adopted or pushed files all carry it).
    func memberPaths(of link: SourceLink) -> [String] {
        guard let info = plugin(link.pluginID)?.manifest.source, let tags else {
            return []
        }
        return tags.paths(taggedWith: SourceEngine.tag(for: info, collectionTitle: link.collection.title))
    }

    /// Board files not yet in the link's collection (no origin record for it).
    func unsentPaths(_ paths: [String], link: SourceLink) -> [String] {
        paths.filter { path in
            !FileOrigin.records(of: URL(fileURLWithPath: path)).contains {
                $0.plugin == link.pluginID && $0.collection == link.collection.id
            }
        }
    }

    private func upsert(_ link: SourceLink) {
        if let i = links.firstIndex(where: { $0.id == link.id }) {
            links[i] = link
        } else {
            links.append(link)
        }
        saveLinks()
    }

    private var linksURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/Sources/links.json")
    }

    private func loadLinks() {
        guard let data = try? Data(contentsOf: linksURL),
              let decoded = try? PluginCoder.decoder.decode([SourceLink].self, from: data) else {
            return
        }
        links = decoded
    }

    private func saveLinks() {
        let url = linksURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PluginCoder.encoder.encode(links) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
