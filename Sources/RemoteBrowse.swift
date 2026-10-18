import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Shows a connected service's items in the main grid. Each item is a preview
/// file in a disposable cache, so the grid, Quick Look, the preview pane and
/// drag all work as they do for library files. Tagging a preview (or dropping
/// it on a board) saves the real item into the library first.
@MainActor
protocol RemoteResultsHandler: AnyObject {
    nonisolated func isRemote(_ url: URL) -> Bool
    /// The saved library files for these previews. `tagging` = the caller is
    /// about to add its own tag, so the collection's tag is optional.
    func libraryFiles(for urls: [URL], tagging: Bool) async -> [URL]
}

/// Preview files for remote items, kept under Caches and trimmed to a size cap.
enum RemotePreviewCache {
    static let limit: Int64 = 500 * 1024 * 1024

    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlap/Remote", isDirectory: true)
    }

    nonisolated static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    /// A folder standing in for a collection; its name is the title.
    nonisolated static func collectionFolder(plugin: String, collection: SourceCollection) -> URL {
        let folder = root
            .appendingPathComponent(safe(plugin), isDirectory: true)
            .appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(safe(collection.id), isDirectory: true)
            .appendingPathComponent(SourceEngine.sanitized(collection.title, fallback: "Untitled"), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The item's preview file, downloading it when it isn't cached yet.
    /// Items without an image become a text or link file, so every item shows.
    nonisolated static func preview(plugin: String, item: SourceItem) async -> URL? {
        let fm = FileManager.default
        let folder = root
            .appendingPathComponent(safe(plugin), isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(safe(item.remoteId), isDirectory: true)
        if let cached = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]).first {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return describe(cached, plugin: plugin, item: item)
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SourceEngine.sanitized(item.title ?? item.filename ?? "", fallback: item.kind.capitalized)
        let base = (name as NSString).deletingPathExtension.isEmpty ? name : (name as NSString).deletingPathExtension

        if let link = item.previewURL, let url = URL(string: link),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !data.isEmpty {
            let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
                ?? (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            let file = folder.appendingPathComponent(base + "." + ext)
            if (try? data.write(to: file)) != nil {
                return describe(file, plugin: plugin, item: item)
            }
        }
        if let text = item.text, !text.isEmpty {
            let file = folder.appendingPathComponent(base + ".txt")
            return (try? Data(text.utf8).write(to: file)) != nil ? file : nil
        }
        if let link = item.sourceURL ?? item.url,
           let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": link], format: .xml, options: 0) {
            let file = folder.appendingPathComponent(base + ".webloc")
            return (try? data.write(to: file)) != nil ? file : nil
        }
        return nil
    }

    /// Give a preview the same origin record a saved file gets, so the play
    /// badge, the player and "Open Video" work before saving too.
    nonisolated private static func describe(_ file: URL, plugin: String, item: SourceItem) -> URL {
        if item.embedHTML != nil || item.kind == "link" || item.kind == "embed" {
            FileOrigin.add(OriginRecord(plugin: plugin, remoteId: item.remoteId, collection: "",
                                        url: item.url, kind: item.kind, source: item.sourceURL,
                                        embed: item.embedHTML), to: file)
        }
        return file
    }

    /// Drop the least recently shown previews until the cache fits the cap.
    nonisolated static func trim() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return
        }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > limit else {
            return
        }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? fm.removeItem(at: file.url.deletingLastPathComponent())
            total -= file.size
        }
    }

    nonisolated private static func safe(_ id: String) -> String {
        SourceEngine.sanitized(id, fallback: "item")
    }
}

/// Where remote mode is and what it has loaded.
@MainActor
final class RemoteBrowseModel: ObservableObject, RemoteResultsHandler {
    enum Location: Hashable {
        case scope(BrowseScope, query: String)
        case collection(SourceCollection)
        /// The collections a given item is in.
        case connections(SourceItem)
    }

    @Published private(set) var pluginID: String?
    @Published private(set) var history: [Location] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    /// Remote ids already in the library.
    @Published private(set) var saved: Set<String> = []
    /// The open collection owner's other collections.
    @Published private(set) var nearby: [SourceCollection] = []
    @Published var searchText = ""

    private enum Content {
        case collection(SourceCollection)
        case item(SourceItem)
    }

    private struct Entry {
        let content: Content
        var file: FileItem?
    }

    private var entries: [Entry] = []
    private var indexByPath: [String: Int] = [:]
    private var cursor: String?
    private var generation = 0
    private weak var sources: SourceStore?
    private weak var tags: TagStore?
    private var watchers: [AnyCancellable] = []

    var plugin: DiscoveredPlugin? { pluginID.flatMap { sources?.plugin($0) } }
    var info: SourceInfo? { plugin?.manifest.source }
    var location: Location? { history.last }
    var scopes: [BrowseScope] { pluginID.flatMap { sources?.accounts[$0]?.browseScopes } ?? [] }

    var signedOut: Bool {
        pluginID.flatMap { sources?.accounts[$0]?.authenticated } == false
    }

    func attach(sources: SourceStore, tags: TagStore) {
        guard self.sources == nil else {
            return
        }
        self.sources = sources
        self.tags = tags
        tags.remoteHandler = self
        watchers.append(sources.$browseTarget.compactMap { $0 }.sink { [weak self] target in
            Task { @MainActor in
                self?.follow(target)
            }
        })
        watchers.append(sources.$finishedPull.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSaved()
            }
        })
    }

    // MARK: - Navigation

    /// Show a service in the main window: a collection, a scope, or its first
    /// browsable scope.
    func open(pluginID: String, at target: Location? = nil) {
        let switching = pluginID != self.pluginID
        self.pluginID = pluginID
        if switching {
            history = []
            saved = []
        }
        tags?.setMode(.remote)
        SidebarService.show(pluginID)
        MainWindowRef.window?.makeKeyAndOrderFront(nil)
        Task {
            if let plugin, sources?.accounts[pluginID] == nil {
                await sources?.checkAccount(plugin)
            }
            if switching {
                await refreshSaved()
            }
            if let target {
                go(target)
            } else if history.isEmpty, let first = scopes.first(where: { $0.takesQuery != true }) {
                go(.scope(first, query: ""))
            } else {
                publish()
            }
        }
    }

    func go(_ next: Location, replace: Bool = false) {
        if replace, !history.isEmpty {
            history.removeLast()
        }
        if history.last != next {
            history.append(next)
        }
        reload()
    }

    func back() {
        guard history.count > 1 else {
            return
        }
        history.removeLast()
        reload()
    }

    func isCurrent(_ scope: BrowseScope) -> Bool {
        if case .scope(let current, _) = location {
            return current.id == scope.id
        }
        return false
    }

    func isCurrent(_ collection: SourceCollection) -> Bool {
        if case .collection(let current) = location {
            return current.id == collection.id
        }
        return false
    }

    func search() {
        if case .scope(let scope, _) = location, scope.takesQuery == true {
            go(.scope(scope, query: searchText), replace: true)
        } else if let scope = scopes.first(where: { $0.takesQuery == true }) {
            go(.scope(scope, query: searchText))
        }
    }

    /// Open a pasted collection link; the error to show, or nil on success.
    func openLink(_ text: String, pluginID: String) async -> String? {
        guard let sources, let plugin = sources.plugin(pluginID) else {
            return "The plugin isn't available."
        }
        switch await sources.resolve(text, plugin: plugin) {
        case .success(let collection):
            open(pluginID: pluginID, at: .collection(collection))
            return nil
        case .failure(let failure):
            return failure.localizedDescription
        }
    }

    private func follow(_ target: SourceStore.BrowseTarget) {
        sources?.browseTarget = nil
        open(pluginID: target.pluginID, at: target.collection.map { .collection($0) })
    }

    // MARK: - Loading

    func reload() {
        generation += 1
        entries = []
        indexByPath = [:]
        cursor = nil
        hasMore = false
        nearby = []
        error = nil
        tags?.selection = []
        publish()
        load()
        if case .collection(let collection) = location {
            loadNearby(collection)
        }
    }

    func loadMore() {
        guard hasMore, !loading else {
            return
        }
        load()
    }

    private func load() {
        guard let plugin, let sources, let location else {
            return
        }
        let generation = generation
        let cursor = cursor
        loading = true
        Task {
            var collections: [SourceCollection] = []
            var items: [SourceItem] = []
            var next: String?
            var failure: String?
            switch location {
            case .scope(let scope, let query):
                if scope.takesQuery == true && query.isEmpty {
                    break
                }
                switch await sources.browse(plugin, scope: scope.id, query: query, cursor: cursor) {
                case .success(let page):
                    collections = page.collections ?? []
                    items = page.items ?? []
                    next = page.nextCursor
                case .failure(let error):
                    failure = error.localizedDescription
                }
            case .collection(let collection):
                switch await sources.browse(plugin, scope: "collection", collection: collection.id, cursor: cursor) {
                case .success(let page):
                    collections = page.collections ?? []
                    items = page.items ?? []
                    next = page.nextCursor
                case .failure(let error):
                    failure = error.localizedDescription
                }
            case .connections(let item):
                switch await sources.related(plugin, remoteId: item.remoteId) {
                case .success(let list):
                    collections = list
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
            guard generation == self.generation else {
                return
            }
            loading = false
            error = failure
            self.cursor = next
            hasMore = next != nil
            append(collections: collections, items: items, plugin: plugin.id, generation: generation)
        }
    }

    private func append(collections: [SourceCollection], items: [SourceItem], plugin: String, generation: Int) {
        var seen = Set(entries.map { entry -> String in
            switch entry.content {
            case .collection(let collection):
                return "c:" + collection.id
            case .item(let item):
                return "i:" + item.remoteId
            }
        })
        let start = entries.count
        for collection in collections where seen.insert("c:" + collection.id).inserted {
            let folder = RemotePreviewCache.collectionFolder(plugin: plugin, collection: collection)
            entries.append(Entry(content: .collection(collection), file: FileItem.load(folder)))
        }
        for item in items where seen.insert("i:" + item.remoteId).inserted {
            entries.append(Entry(content: .item(item), file: nil))
        }
        reindex()
        publish()
        let pending = (start..<entries.count).compactMap { index -> (Int, SourceItem)? in
            if case .item(let item) = entries[index].content {
                return (index, item)
            }
            return nil
        }
        Task {
            await withTaskGroup(of: (Int, FileItem?).self) { group in
                var queued = pending[...]
                func enqueue() {
                    guard let (index, item) = queued.popFirst() else {
                        return
                    }
                    group.addTask {
                        let file = await RemotePreviewCache.preview(plugin: plugin, item: item)
                        return (index, file.map(FileItem.load))
                    }
                }
                for _ in 0..<6 {
                    enqueue()
                }
                for await (index, file) in group {
                    guard generation == self.generation else {
                        group.cancelAll()
                        return
                    }
                    entries[index].file = file
                    reindex()
                    publish()
                    enqueue()
                }
            }
            Task.detached(priority: .utility) {
                RemotePreviewCache.trim()
            }
        }
    }

    /// Hand the grid every entry up to the first preview still downloading, so
    /// tiles appear in the service's order without jumping around.
    private func publish() {
        var ready: [FileItem] = []
        for entry in entries {
            guard let file = entry.file else {
                if case .item = entry.content {
                    break
                }
                continue
            }
            ready.append(file)
        }
        tags?.showRemote(ready)
    }

    private func reindex() {
        indexByPath = [:]
        for (index, entry) in entries.enumerated() {
            if let path = entry.file?.id {
                indexByPath[path] = index
            }
        }
    }

    var stillLoadingPreviews: Bool {
        entries.contains { $0.file == nil }
    }

    private func loadNearby(_ collection: SourceCollection) {
        guard let plugin, let sources else {
            return
        }
        let generation = generation
        Task {
            if case .success(let list) = await sources.related(plugin, collection: collection.id),
               generation == self.generation {
                nearby = list.filter { $0.id != collection.id }
            }
        }
    }

    // MARK: - Items

    nonisolated func isRemote(_ url: URL) -> Bool {
        RemotePreviewCache.contains(url)
    }

    private func content(at url: URL) -> Content? {
        indexByPath[url.path].map { entries[$0].content }
    }

    func item(at url: URL) -> SourceItem? {
        if case .item(let item)? = content(at: url) {
            return item
        }
        return nil
    }

    func collection(at url: URL) -> SourceCollection? {
        if case .collection(let collection)? = content(at: url) {
            return collection
        }
        return nil
    }

    func isSaved(_ url: URL) -> Bool {
        item(at: url).map { saved.contains($0.remoteId) } ?? false
    }

    /// Double-click: step into a collection; anything else is Quick Look's.
    func open(_ url: URL) -> Bool {
        guard let collection = collection(at: url) else {
            return false
        }
        go(.collection(collection))
        return true
    }

    func webPage(for url: URL) -> URL? {
        let link = item(at: url)?.url ?? collection(at: url)?.url
        return link.flatMap(URL.init(string:))
    }

    var currentWebPage: URL? {
        if case .collection(let collection) = location {
            return collection.url.flatMap(URL.init(string:))
        }
        return nil
    }

    func showConnections(of url: URL) {
        if let item = item(at: url) {
            go(.connections(item))
        }
    }

    // MARK: - Saving

    func libraryFiles(for urls: [URL], tagging: Bool) async -> [URL] {
        guard let plugin, let sources else {
            return []
        }
        let current: SourceCollection?
        if case .collection(let collection) = location {
            current = collection
        } else {
            current = nil
        }
        let picks = urls.compactMap { url -> SourceEngine.Pick? in
            guard let item = item(at: url) else {
                return nil
            }
            return SourceEngine.Pick(item: item, collection: current ?? item.via ?? SourceEngine.savedCollection())
        }
        guard !picks.isEmpty else {
            return []
        }
        let tagCollections = !tagging || sources.tagsSavedWithCollection(plugin)
        let files = await sources.saveNow(picks, plugin: plugin, tagCollections: tagCollections)
        saved.formUnion(files.keys)
        return picks.compactMap { files[$0.item.remoteId] }
    }

    func save(_ urls: [URL]) {
        Task {
            _ = await libraryFiles(for: urls, tagging: false)
        }
    }

    func importAll() {
        guard let plugin, let sources, case .collection(let collection) = location else {
            return
        }
        if let link = sources.link(for: collection, plugin: plugin) {
            sources.sync(link)
        } else if let destination = sources.defaultDestination(for: collection, plugin: plugin) {
            sources.importCollection(collection, plugin: plugin, destination: destination, includeTextAndLinks: true)
        }
    }

    var currentIsSynced: Bool {
        guard let plugin, let sources, case .collection(let collection) = location else {
            return false
        }
        return sources.link(for: collection, plugin: plugin) != nil
    }

    private func refreshSaved() async {
        if let plugin, let sources {
            saved = await sources.savedRemoteIds(plugin)
        }
    }
}
