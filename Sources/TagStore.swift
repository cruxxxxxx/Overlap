import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

/// One reversible action: an inverse (`undo`) and a re-do closure.
private struct UndoStep {
    let name: String
    let undo: () -> Void
    let redo: () -> Void
}

/// Central model. One live Spotlight query gathers every tagged file under the
/// scope (with its tags) into memory; the tag tree, counts, and boolean
/// filtering all run client-side. Every mutation records an inverse so it can
/// be undone/redone.
@MainActor
final class TagStore: ObservableObject {

    // Scope
    @Published var scopeURL: URL

    // Catalog
    @Published var tagTree: [TagNode] = []
    @Published var tagCounts: [String: Int] = [:]
    @Published var isIndexing = false

    // Filter
    @Published private(set) var tagState: [String: TriState] = [:]
    @Published private(set) var includeGroups: [String: Int] = [:]  // tag -> OR group
    @Published var matchMode: MatchMode = .all
    static let maxGroups = 4

    /// User-created tags kept in the tree even when no file carries them yet.
    @Published var knownTags: Set<String> = []
    /// Custom order for top-level tags (names). Unlisted ones fall back to A→Z.
    @Published var tagOrder: [String] = []

    // Results
    @Published var results: [FileItem] = []
    @Published var sortKey: SortKey = .name
    @Published var sortAscending = true
    @Published var selection: Set<String> = []
    @Published var selectionAnchor: String?   // for shift-click range selection
    @Published var scrollTarget: String?
    @Published var tagFocusRequest = 0   // bump to focus the quick-tag field
    @Published var showPreview = false {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    var columnsHint = 1

    func requestTagFocus() { tagFocusRequest &+= 1 }

    // Queue
    @Published var mode: LibraryMode = .tags
    @Published var queueFolders: [URL] = []
    @Published var queueItems: [FileItem] = []
    @Published var queueRecursive = false

    // Undo
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []

    private var allItems: [FileItem] = []
    private let catalogQuery = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let tagAttr = "kMDItemUserTags"
    private let imageExts: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    private let foldersDefaultsKey = "queueFolders"
    private let recursiveDefaultsKey = "queueRecursive"

    init(scope: URL) {
        self.scopeURL = scope
        loadQueueFolders()
        wireQueries()
        start()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Query setup

    private func wireQueries() {
        catalogQuery.searchScopes = [scopeURL]
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: catalogQuery,
            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildCatalog() } })
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: catalogQuery,
            queue: .main) { [weak self] note in MainActor.assumeIsolated { self?.catalogUpdate(note) } })
    }

    func start() {
        isIndexing = true
        catalogQuery.predicate = NSPredicate(format: "%K LIKE %@", tagAttr, "*")
        catalogQuery.start()
    }

    func setScope(_ url: URL) {
        scopeURL = url
        catalogQuery.stop()
        catalogQuery.searchScopes = [url]
        start()
    }

    // MARK: - Catalog

    private func rebuildCatalog() {
        catalogQuery.disableUpdates()
        var counts: [String: Int] = [:]
        var items: [FileItem] = []
        for i in 0..<catalogQuery.resultCount {
            guard let item = catalogQuery.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let tags = item.value(forAttribute: tagAttr) as? [String] else { continue }
            for tag in tags { counts[tag, default: 0] += 1 }
            let mod = item.value(forAttribute: "kMDItemContentModificationDate") as? Date
            let created = item.value(forAttribute: "kMDItemContentCreationDate") as? Date
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value
            items.append(FileItem(url: URL(fileURLWithPath: path), tags: tags,
                                  modDate: mod, createdDate: created, size: size))
        }
        catalogQuery.enableUpdates()
        allItems = items
        applyCounts(counts)
        isIndexing = false
        refreshVisible()
    }

    /// Incremental update: apply only the items Spotlight reports as
    /// added/changed/removed, instead of rescanning the whole catalog.
    private func catalogUpdate(_ note: Notification) {
        catalogQuery.disableUpdates()
        defer { catalogQuery.enableUpdates() }

        func items(_ key: String) -> [NSMetadataItem] {
            (note.userInfo?[key] as? [NSMetadataItem]) ?? []
        }
        let added = items(NSMetadataQueryUpdateAddedItemsKey)
        let changed = items(NSMetadataQueryUpdateChangedItemsKey)
        let removed = items(NSMetadataQueryUpdateRemovedItemsKey)
        guard !added.isEmpty || !changed.isEmpty || !removed.isEmpty else { return }

        for item in added + changed {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            // Read from disk, not Spotlight's (briefly stale) index — avoids the
            // count flickering up/down right after an edit.
            let fi = FileItem.load(URL(fileURLWithPath: path))
            if let idx = allItems.firstIndex(where: { $0.id == fi.id }) {
                allItems[idx] = fi
            } else {
                allItems.append(fi)
            }
        }
        for item in removed {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                allItems.removeAll { $0.id == path }
            }
        }
        if !added.isEmpty || !removed.isEmpty {
            allItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        recomputeCounts()
        refreshVisible()
    }

    private func applyCounts(_ counts: [String: Int]) {
        var merged = counts
        for t in knownTags where merged[t] == nil { merged[t] = 0 }
        tagCounts = merged
        tagTree = TagNode.buildTree(from: merged)
    }

    /// Create a tag (or subtag) in the taxonomy without needing a file yet.
    func reorderTopTags(_ names: [String], from: IndexSet, to: Int) {
        var order = names
        order.move(fromOffsets: from, toOffset: to)
        tagOrder = order
        UserDefaults.standard.set(order, forKey: "tagOrder")
    }

    func addKnownTag(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !t.isEmpty else { return }
        knownTags.insert(t)
        saveKnownTags()
        recomputeCounts()
    }

    private func saveKnownTags() {
        UserDefaults.standard.set(Array(knownTags), forKey: "knownTags")
    }

    private func recomputeCounts() {
        var counts: [String: Int] = [:]
        for item in allItems { for tag in item.tags { counts[tag, default: 0] += 1 } }
        applyCounts(counts)
    }

    // MARK: - Filter mutation

    func state(for tag: String) -> TriState { tagState[tag] ?? .off }

    func cycle(_ tag: String) {
        let next = state(for: tag).next
        if next == .off { tagState.removeValue(forKey: tag) } else { tagState[tag] = next }
        if next != .include { includeGroups.removeValue(forKey: tag) }
        refreshResults()
    }

    func set(_ tag: String, to s: TriState) {
        if s == .off { tagState.removeValue(forKey: tag) } else { tagState[tag] = s }
        if s != .include { includeGroups.removeValue(forKey: tag) }
        refreshResults()
    }

    func clearFilter() { tagState.removeAll(); includeGroups.removeAll(); refreshResults() }
    func setMatchMode(_ m: MatchMode) { matchMode = m; refreshResults() }

    func groupOf(_ tag: String) -> Int { includeGroups[tag] ?? 0 }
    func cycleIncludeGroup(_ tag: String) {
        includeGroups[tag] = (groupOf(tag) + 1) % Self.maxGroups
        refreshResults()
    }

    var activeIncludes: [String] { tagState.filter { $0.value == .include }.keys.sorted() }
    var activeExcludes: [String] { tagState.filter { $0.value == .exclude }.keys.sorted() }

    // MARK: - Client-side filtering

    private func isPrefix(_ tag: String) -> Bool {
        tagCounts[tag] == nil && tagCounts.keys.contains { $0.hasPrefix(tag + "/") }
    }

    func refreshResults() {
        let inc = activeIncludes.map { (tag: $0, prefix: isPrefix($0)) }
        let exc = activeExcludes.map { (tag: $0, prefix: isPrefix($0)) }
        guard !inc.isEmpty || !exc.isEmpty else { results = []; return }
        let mode = matchMode
        let incSet = Set(activeIncludes)

        func has(_ t: (tag: String, prefix: Bool), _ set: Set<String>) -> Bool {
            if set.contains(t.tag) { return true }
            return t.prefix && set.contains { $0.hasPrefix(t.tag + "/") }
        }
        let filtered = allItems.filter { item in
            let s = item.tagSet
            if !inc.isEmpty {
                let ok: Bool
                switch mode {
                case .all:  ok = inc.allSatisfy { has($0, s) }
                case .any:  ok = inc.contains { has($0, s) }
                case .only: ok = (s == incSet)   // exactly these tags, nothing else
                case .groups:
                    // OR within each group letter, AND across groups.
                    let grouped = Dictionary(grouping: inc) { groupOf($0.tag) }
                    ok = grouped.values.allSatisfy { g in g.contains { has($0, s) } }
                }
                if !ok { return false }
            }
            for e in exc where has(e, s) { return false }
            return true
        }
        results = sortItems(filtered)
    }

    private func refreshVisible() {
        if mode == .tags { refreshResults() } else { results = sortItems(queueItems) }
    }

    // MARK: - Sorting

    func sortItems(_ items: [FileItem]) -> [FileItem] {
        let sorted: [FileItem]
        switch sortKey {
        case .name:
            sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type:
            sorted = items.sorted {
                $0.ext == $1.ext
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.ext < $1.ext
            }
        case .dateModified:
            sorted = items.sorted { ($0.modDate ?? .distantPast) < ($1.modDate ?? .distantPast) }
        case .dateCreated:
            sorted = items.sorted { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
        case .size:
            sorted = items.sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    func setSortKey(_ key: SortKey) {
        sortKey = key
        UserDefaults.standard.set(key.rawValue, forKey: "sortKey")
        refreshVisible()
    }

    func setSortAscending(_ asc: Bool) {
        sortAscending = asc
        UserDefaults.standard.set(asc, forKey: "sortAscending")
        refreshVisible()
    }

    // MARK: - Undo infrastructure

    private func push(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(UndoStep(name: name, undo: undo, redo: redo))
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    func performUndo() {
        guard let step = undoStack.popLast() else { return }
        step.undo()
        redoStack.append(step)
        updateUndoFlags()
    }

    func performRedo() {
        guard let step = redoStack.popLast() else { return }
        step.redo()
        undoStack.append(step)
        updateUndoFlags()
    }

    // MARK: - Low-level (non-registering) mutations

    private func syncTags(for urls: [URL]) {
        let ids = Set(urls.map { $0.path })
        for i in allItems.indices where ids.contains(allItems[i].id) {
            allItems[i] = FileItem.load(allItems[i].url)
        }
        for i in queueItems.indices where ids.contains(queueItems[i].id) {
            queueItems[i] = FileItem.load(queueItems[i].url)
        }
        recomputeCounts()
        refreshVisible()
    }

    private func lowSetTag(_ tag: String, on urls: [URL], add: Bool) {
        if add { TagIO.addTag(tag, to: urls) } else { TagIO.removeTag(tag, from: urls) }
        syncTags(for: urls)
    }

    private func lowRename(_ from: String, to: String, urls: [URL]) {
        TagIO.renameTag(from, to: to, in: urls)
        syncTags(for: urls)
    }

    // MARK: - Public tag editing (registers undo)

    func addTag(_ tag: String, to urls: [URL]) {
        let changed = urls.filter { !TagIO.tags(of: $0).contains(tag) }
        guard !changed.isEmpty else { return }
        lowSetTag(tag, on: changed, add: true)
        push("Add “\(tag)”",
             undo: { [weak self] in self?.lowSetTag(tag, on: changed, add: false) },
             redo: { [weak self] in self?.lowSetTag(tag, on: changed, add: true) })
    }

    func removeTag(_ tag: String, from urls: [URL]) {
        let changed = urls.filter { TagIO.tags(of: $0).contains(tag) }
        guard !changed.isEmpty else { return }
        lowSetTag(tag, on: changed, add: false)
        push("Remove “\(tag)”",
             undo: { [weak self] in self?.lowSetTag(tag, on: changed, add: true) },
             redo: { [weak self] in self?.lowSetTag(tag, on: changed, add: false) })
    }

    func renameTagEverywhere(_ old: String, to new: String) {
        let cleanNew = new.trimmingCharacters(in: .whitespaces)
        let urls = allURLs(withTag: old)
        let wasKnown = knownTags.contains(old)
        guard !cleanNew.isEmpty, !urls.isEmpty || wasKnown else { return }

        func apply(_ from: String, _ to: String) {
            if !urls.isEmpty { lowRename(from, to: to, urls: urls) }
            if knownTags.contains(from) {
                knownTags.remove(from); knownTags.insert(to); saveKnownTags()
            }
            swapState(from, to)
            recomputeCounts()
        }
        apply(old, cleanNew)
        push("Rename “\(old)” → “\(cleanNew)”",
             undo: { [weak self] in self?.applyRename(cleanNew, old, urls: urls) },
             redo: { [weak self] in self?.applyRename(old, cleanNew, urls: urls) })
    }

    private func applyRename(_ from: String, _ to: String, urls: [URL]) {
        if !urls.isEmpty { lowRename(from, to: to, urls: urls) }
        if knownTags.contains(from) {
            knownTags.remove(from); knownTags.insert(to); saveKnownTags()
        }
        swapState(from, to)
        recomputeCounts()
    }

    func deleteTagEverywhere(_ tag: String) {
        let urls = allURLs(withTag: tag)
        let wasKnown = knownTags.contains(tag)
        guard !urls.isEmpty || wasKnown else { tagState.removeValue(forKey: tag); return }
        let hadState = tagState[tag]

        if !urls.isEmpty { lowSetTag(tag, on: urls, add: false) }
        if wasKnown { knownTags.remove(tag); saveKnownTags() }
        tagState.removeValue(forKey: tag)
        recomputeCounts(); refreshVisible()

        push("Delete “\(tag)”",
             undo: { [weak self] in
                 guard let self else { return }
                 if !urls.isEmpty { self.lowSetTag(tag, on: urls, add: true) }
                 if wasKnown { self.knownTags.insert(tag); self.saveKnownTags() }
                 if let hadState { self.tagState[tag] = hadState }
                 self.recomputeCounts(); self.refreshVisible()
             },
             redo: { [weak self] in
                 guard let self else { return }
                 if !urls.isEmpty { self.lowSetTag(tag, on: urls, add: false) }
                 if wasKnown { self.knownTags.remove(tag); self.saveKnownTags() }
                 self.tagState.removeValue(forKey: tag)
                 self.recomputeCounts(); self.refreshVisible()
             })
    }

    private func swapState(_ from: String, _ to: String) {
        if let s = tagState[from] { tagState.removeValue(forKey: from); tagState[to] = s }
    }

    /// Merge one tag into another across the whole library (files with the
    /// source tag get the target instead; duplicates collapse).
    func mergeTag(_ source: String, into target: String) {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != source else { return }
        renameTagEverywhere(source, to: t)
    }

    // MARK: - Fix extension (registers undo)

    func fixExtension(_ urls: [URL]) {
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        for url in urls {
            guard let ext = Self.correctExtension(for: url),
                  url.pathExtension.lowercased() != ext else { continue }
            let dir = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let dest = uniqueDestination(in: dir, name: "\(base).\(ext)")
            if (try? fm.moveItem(at: url, to: dest)) != nil { moves.append((url, dest)) }
        }
        guard !moves.isEmpty else { return }
        remapItems(moves)
        push("Fix \(moves.count) extension\(moves.count > 1 ? "s" : "")",
             undo: { [weak self] in self?.applyDiskMoves(moves.map { (from: $0.to, to: $0.from) }) },
             redo: { [weak self] in self?.applyDiskMoves(moves) })
    }

    static func correctExtension(for url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(src) as String?,
              let ext = UTType(uti)?.preferredFilenameExtension else { return nil }
        return ext.lowercased()
    }

    private func applyDiskMoves(_ moves: [(from: URL, to: URL)]) {
        let fm = FileManager.default
        for m in moves { try? fm.moveItem(at: m.from, to: m.to) }
        remapItems(moves)
    }

    /// After files move on disk, update in-memory ids/paths and selection.
    private func remapItems(_ moves: [(from: URL, to: URL)]) {
        let map = Dictionary(uniqueKeysWithValues: moves.map { ($0.from.path, $0.to) })
        for i in allItems.indices { if let to = map[allItems[i].id] { allItems[i] = FileItem.load(to) } }
        for i in queueItems.indices { if let to = map[queueItems[i].id] { queueItems[i] = FileItem.load(to) } }
        var newSel = selection
        for m in moves where newSel.remove(m.from.path) != nil { newSel.insert(m.to.path) }
        selection = newSel
        recomputeCounts()
        refreshVisible()
    }

    // MARK: - Trash (registers undo)

    func trash(_ urls: [URL]) {
        let pairs = lowTrash(urls)
        guard !pairs.isEmpty else { return }
        push("Move \(pairs.count) to Trash",
             undo: { [weak self] in self?.lowRestore(pairs) },
             redo: { [weak self] in _ = self?.lowTrash(pairs.map { $0.original }) })
    }

    private func lowTrash(_ urls: [URL]) -> [(original: URL, inTrash: URL)] {
        guard !urls.isEmpty else { return [] }
        let ids = Set(urls.map { $0.path })
        let anchor = results.firstIndex { ids.contains($0.id) }
        var pairs: [(URL, URL)] = []
        for url in urls {
            var out: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &out)) != nil,
               let dest = out as URL? {
                pairs.append((url, dest))
            }
        }
        allItems.removeAll { ids.contains($0.id) }
        queueItems.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        recomputeCounts()
        refreshVisible()
        if let anchor, !results.isEmpty {
            let id = results[min(anchor, results.count - 1)].id
            selection = [id]; scrollTarget = id
        }
        return pairs
    }

    private func lowRestore(_ pairs: [(original: URL, inTrash: URL)]) {
        for p in pairs { try? FileManager.default.moveItem(at: p.inTrash, to: p.original) }
        readd(pairs.map { $0.original })
    }

    /// Re-add restored/returned files to the right in-memory list.
    private func readd(_ urls: [URL]) {
        for url in urls {
            let item = FileItem.load(url)
            if url.path.hasPrefix(scopeURL.path),
               !allItems.contains(where: { $0.id == item.id }) {
                allItems.append(item)
            }
            if item.tags.isEmpty,
               queueFolders.contains(where: { url.path.hasPrefix($0.path) }),
               !queueItems.contains(where: { $0.id == item.id }) {
                queueItems.append(item)
            }
        }
        recomputeCounts()
        refreshVisible()
    }

    // MARK: - Selection movement

    func selectedURLs() -> [URL] {
        results.filter { selection.contains($0.id) }.map { $0.url }
    }

    func moveSelection(dx: Int, dy: Int) {
        guard !results.isEmpty else { return }
        let idx: Int
        if let cur = results.firstIndex(where: { selection.contains($0.id) }) {
            idx = min(max(cur + dx + dy * max(1, columnsHint), 0), results.count - 1)
        } else { idx = 0 }
        let id = results[idx].id
        selection = [id]; selectionAnchor = id; scrollTarget = id
    }

    // MARK: - Queue

    func setMode(_ m: LibraryMode) {
        guard m != mode else { return }
        mode = m
        selection = []
        if m == .queue { scanQueue() } else { refreshResults() }
    }

    private func isImage(_ url: URL) -> Bool {
        imageExts.contains(url.pathExtension.lowercased())
    }

    func scanQueue() {
        let fm = FileManager.default
        var found: [FileItem] = []
        for folder in queueFolders {
            for url in imageURLs(in: folder, fm: fm) {
                let fi = FileItem.load(url)
                if fi.tags.isEmpty { found.append(fi) }
            }
        }
        queueItems = found
        if mode == .queue { selection = []; results = sortItems(found) }
    }

    private func imageURLs(in folder: URL, fm: FileManager) -> [URL] {
        if queueRecursive {
            var acc: [URL] = []
            let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = en?.nextObject() as? URL { if isImage(url) { acc.append(url) } }
            return acc
        }
        let contents = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter(isImage)
    }

    func setQueueRecursive(_ on: Bool) {
        queueRecursive = on
        UserDefaults.standard.set(on, forKey: recursiveDefaultsKey)
        scanQueue()
    }

    var taggedQueueCount: Int { queueItems.filter { !$0.tags.isEmpty }.count }

    func addQueueFolder(_ url: URL) {
        guard !queueFolders.contains(url) else { return }
        queueFolders.append(url); saveQueueFolders(); scanQueue()
    }

    func removeQueueFolder(_ url: URL) {
        queueFolders.removeAll { $0 == url }; saveQueueFolders(); scanQueue()
    }

    // MARK: - Apply queue (registers undo)

    func applyQueue() {
        let moves = lowMoveToLibrary(queueItems.filter { !$0.tags.isEmpty }.map { $0.url })
        guard !moves.isEmpty else { return }
        push("Apply \(moves.count) to Library",
             undo: { [weak self] in self?.lowMoveBack(moves) },
             redo: { [weak self] in _ = self?.lowMoveToLibrary(moves.map { $0.from }) })
    }

    private func lowMoveToLibrary(_ urls: [URL]) -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        var moves: [(URL, URL)] = []
        for url in urls {
            let target = uniqueDestination(in: scopeURL, name: url.lastPathComponent)
            if (try? fm.moveItem(at: url, to: target)) != nil { moves.append((url, target)) }
        }
        let movedIDs = Set(moves.map { $0.0.path })
        queueItems.removeAll { movedIDs.contains($0.id) }
        selection.subtract(movedIDs)
        refreshVisible()
        return moves
    }

    private func lowMoveBack(_ moves: [(from: URL, to: URL)]) {
        let fm = FileManager.default
        for m in moves {
            let dir = m.from.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: m.to, to: m.from)
        }
        let toIDs = Set(moves.map { $0.to.path })
        allItems.removeAll { toIDs.contains($0.id) }
        readd(moves.map { $0.from })
    }

    private func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func allURLs(withTag tag: String) -> [URL] {
        allItems.filter { $0.tagSet.contains(tag) }.map { $0.url }
    }

    // MARK: - Stats

    struct LibraryStats {
        let total: Int
        let totalSize: Int64
        let tagCount: Int
        let untagged: Int
        let byType: [(String, Int)]
        let topTags: [(String, Int)]
        let largest: FileItem?
    }

    func libraryStats() -> LibraryStats {
        var typeCounts: [String: Int] = [:]
        var totalSize: Int64 = 0
        var untagged = 0
        for item in allItems {
            typeCounts[item.ext.isEmpty ? "—" : item.ext, default: 0] += 1
            totalSize += item.size ?? 0
            if item.tags.isEmpty { untagged += 1 }
        }
        let byType = typeCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let topTags = tagCounts.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(15).map { ($0.key, $0.value) }
        let largest = allItems.max { ($0.size ?? 0) < ($1.size ?? 0) }
        return LibraryStats(
            total: allItems.count,
            totalSize: totalSize,
            tagCount: tagCounts.filter { $0.value > 0 }.count,
            untagged: untagged,
            byType: byType,
            topTags: Array(topTags),
            largest: largest)
    }

    // MARK: - Persistence

    private func loadQueueFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: foldersDefaultsKey) ?? []
        var urls = paths.map { URL(fileURLWithPath: $0) }
        if urls.isEmpty {
            urls = [fmHome.appendingPathComponent("Downloads", isDirectory: true)]
        }
        queueFolders = urls
        queueRecursive = UserDefaults.standard.bool(forKey: recursiveDefaultsKey)
        showPreview = UserDefaults.standard.bool(forKey: "showPreview")
        knownTags = Set(UserDefaults.standard.stringArray(forKey: "knownTags") ?? [])
        tagOrder = UserDefaults.standard.stringArray(forKey: "tagOrder") ?? []
        if let raw = UserDefaults.standard.string(forKey: "sortKey"),
           let key = SortKey(rawValue: raw) { sortKey = key }
        if UserDefaults.standard.object(forKey: "sortAscending") != nil {
            sortAscending = UserDefaults.standard.bool(forKey: "sortAscending")
        }
    }

    private func saveQueueFolders() {
        UserDefaults.standard.set(queueFolders.map { $0.path }, forKey: foldersDefaultsKey)
    }

    private var fmHome: URL { FileManager.default.homeDirectoryForCurrentUser }
}
