import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Security

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

    // THE query — single source of truth for every query-building UI.
    // One or more Venn diagrams (groups) that AND together, plus global
    // excludes. Every surface (query bar, sidebar tri-state, diagrams, map)
    // is a different visual method of constructing this same state.
    @Published private(set) var groups: [VennGroup] = { [VennGroup()] }()
    @Published private(set) var activeGroupID = UUID()
    @Published private(set) var queryExcludes: Set<String> = []
    /// User-created tags kept in the tree even when no file carries them yet.
    @Published var knownTags: Set<String> = []
    /// Custom order for top-level tags (names). Unlisted ones fall back to A→Z.
    @Published var tagOrder: [String] = []

    // Hidden tags & default query stance.
    /// Tags whose files vanish from every surface while locked. Applies to the
    /// exact tag and anything beneath it (a hidden `secret` also hides
    /// `secret/…`). Persisted; the reveal state itself is session-only.
    @Published var hiddenTags: Set<String> = []
    /// Whether hidden tags are currently revealed. Always false at launch.
    @Published private(set) var revealed = false
    /// Per-tag default query stance, seeded into every fresh query. A hidden
    /// NSFW tag typically defaults to `.exclude` so it never shows unopted.
    @Published var tagDefaults: [String: TriState] = [:]

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

    /// Filter to a single tag and jump to the grid.
    func focusTag(_ tag: String) {
        clearQuery()
        include(tag)
        mode = .tags
    }

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
    /// allItems minus hidden-tagged files while locked; the pool every surface
    /// (results, counts, tree, Venn, stats) actually reads from.
    private var visibleItems: [FileItem] = []
    private let catalogQuery = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let tagAttr = "kMDItemUserTags"
    private let imageExts: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    private let foldersDefaultsKey = "queueFolders"
    private let recursiveDefaultsKey = "queueRecursive"
    private let hiddenTagsKey = "hiddenTags"
    private let tagDefaultsKey = "tagDefaults"
    private let passSaltKey = "hiddenPassSalt"
    private let passHashKey = "hiddenPassHash"

    init(scope: URL) {
        self.scopeURL = scope
        activeGroupID = groups[0].id
        loadQueueFolders()
        applyQueryDefaults()   // seed the query from per-tag default stances
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

    /// Spotlight can report the same file under either the `/Users/…` firmlink
    /// or its `/System/Volumes/Data/Users/…` backing path. Resolve to one
    /// canonical form so a file is never seen (or appended) twice.
    private func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    private func rebuildCatalog() {
        catalogQuery.disableUpdates()
        var items: [FileItem] = []
        for i in 0..<catalogQuery.resultCount {
            guard let item = catalogQuery.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let tags = item.value(forAttribute: tagAttr) as? [String] else { continue }
            let mod = item.value(forAttribute: "kMDItemContentModificationDate") as? Date
            let created = item.value(forAttribute: "kMDItemContentCreationDate") as? Date
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value
            items.append(FileItem(url: canonicalURL(path), tags: tags,
                                  modDate: mod, createdDate: created, size: size))
        }
        catalogQuery.enableUpdates()
        allItems = Self.deduped(items)
        recomputeCounts()   // rebuilds the visible pool + counts + tree
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
            let fi = FileItem.load(canonicalURL(path))
            if let idx = allItems.firstIndex(where: { $0.id == fi.id }) {
                allItems[idx] = fi
            } else {
                allItems.append(fi)
            }
        }
        for item in removed {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                let key = canonicalURL(path).path
                allItems.removeAll { $0.id == key }
            }
        }
        // Enforce the one-entry-per-path invariant on every catalog change.
        allItems = Self.deduped(allItems)
        if !added.isEmpty || !removed.isEmpty {
            allItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        recomputeCounts()
        refreshVisible()
    }

    private func applyCounts(_ counts: [String: Int]) {
        var merged = counts
        for t in knownTags where merged[t] == nil { merged[t] = 0 }
        // While locked, hidden tags are stripped from the tree entirely so they
        // can't be seen, counted, or added to a query.
        if !revealed {
            merged = merged.filter { !isHiddenTag($0.key) }
        }
        tagCounts = merged
        tagTree = TagNode.buildTree(from: merged)
    }

    // MARK: - Hidden-tag pool

    /// A tag is hidden if it's marked hidden or lives beneath one that is.
    func isHiddenTag(_ tag: String) -> Bool {
        hiddenTags.contains(tag) || hiddenTags.contains { tag.hasPrefix($0 + "/") }
    }

    private func itemHidden(_ item: FileItem) -> Bool {
        item.tagSet.contains { isHiddenTag($0) }
    }

    /// Enforce one entry per path. Spotlight can occasionally surface the same
    /// path twice during a rescan, and stale entries can linger after files
    /// move; either would render a file twice in the grid.
    private static func deduped(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<String>()
        var out: [FileItem] = []
        out.reserveCapacity(items.count)
        for it in items where seen.insert(it.id).inserted {
            out.append(it)
        }
        return out
    }

    /// Recompute the visible pool: everything when revealed (or nothing hidden),
    /// otherwise allItems with hidden-tagged files removed.
    private func rebuildPool() {
        if revealed || hiddenTags.isEmpty {
            visibleItems = allItems
        } else {
            visibleItems = allItems.filter { !itemHidden($0) }
        }
    }

    /// Re-derive everything after the lock state or hidden set changes.
    private func applyVisibility() {
        recomputeCounts()   // rebuilds pool + counts + tree
        reconcileHiddenInQuery()
        refreshResults()
    }

    /// Keep hidden tags out of the visible query while locked (so their names
    /// never surface as chips) and re-seed their opt-in default when revealed.
    private func reconcileHiddenInQuery() {
        if revealed {
            for (tag, stance) in tagDefaults where isHiddenTag(tag) {
                if stance == .exclude, owningGroupIndex(of: tag) == nil {
                    queryExcludes.insert(tag)
                }
            }
        } else {
            for tag in Array(queryExcludes) where isHiddenTag(tag) {
                queryExcludes.remove(tag)
            }
            for gi in groups.indices where groups[gi].sets.contains(where: { isHiddenTag($0) }) {
                let old = groups[gi].sets
                groups[gi].sets = old.filter { !isHiddenTag($0) }
                groups[gi].regions = Self.remapRegions(groups[gi].regions, from: old, to: groups[gi].sets)
            }
        }
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
        rebuildPool()
        var counts: [String: Int] = [:]
        for item in visibleItems { for tag in item.tags { counts[tag, default: 0] += 1 } }
        applyCounts(counts)
    }

    // MARK: - Explore (co-occurrence)

    /// Tags that co-occur with the current include set (AND). Counts = how many
    /// of the current matching images also carry that tag. Linear in the subset.
    func coOccurring() -> [(tag: String, count: Int)] {
        let active = Set(activeIncludes)
        // An empty OR diagram starts a fresh clause — its candidates come from
        // the whole catalog, not the other diagrams' intersection.
        let freshClause = activeGroup.sets.isEmpty && activeGroup.op == .or
        let base = (active.isEmpty || freshClause) ? visibleItems : results
        var counts: [String: Int] = [:]
        for item in base {
            for t in item.tags where !active.contains(t) { counts[t, default: 0] += 1 }
        }
        return counts.sorted {
            $0.value != $1.value ? $0.value > $1.value
                : $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }.map { ($0.key, $0.value) }
    }

    // MARK: - Query mutation (the only way any UI edits the query)

    /// Flat, ordered union of every diagram's sets (sidebar dots, co-occurrence).
    var querySets: [String] {
        var seen = Set<String>()
        return groups.flatMap(\.sets).filter { seen.insert($0).inserted }
    }
    var activeIncludes: [String] { querySets }
    var activeExcludes: [String] { queryExcludes.sorted() }

    var activeGroupIndex: Int {
        groups.firstIndex { $0.id == activeGroupID } ?? 0
    }
    var activeGroup: VennGroup { groups[activeGroupIndex] }

    private func owningGroupIndex(of tag: String) -> Int? {
        groups.firstIndex { $0.sets.contains(tag) }
    }

    func state(for tag: String) -> TriState {
        if owningGroupIndex(of: tag) != nil { return .include }
        if queryExcludes.contains(tag) { return .exclude }
        return .off
    }

    /// The state the user *sees*: a set whose bit is off in every painted
    /// region of its diagram reads as excluded even though it's a circle.
    func effectiveState(for tag: String) -> TriState {
        if regionRole(tag) == .excluded { return .exclude }
        return state(for: tag)
    }

    /// What a diagram's painted regions imply for one of its sets.
    func regionRole(_ tag: String) -> RegionRole? {
        guard let gi = owningGroupIndex(of: tag) else { return nil }
        let g = groups[gi]
        guard !g.regions.isEmpty, let i = g.sets.firstIndex(of: tag) else { return nil }
        let bit = 1 << i
        if g.regions.allSatisfy({ $0 & bit != 0 }) { return .required }
        if g.regions.allSatisfy({ $0 & bit == 0 }) { return .excluded }
        return .mixed
    }

    // MARK: Group management

    func addGroup() {
        let g = VennGroup()
        groups.append(g)
        activeGroupID = g.id
        refreshResults()
    }

    func removeGroup(_ id: UUID) {
        guard groups.count > 1, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups.remove(at: i)
        if activeGroupID == id { activeGroupID = groups[min(i, groups.count - 1)].id }
        refreshResults()
    }

    func activateGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        activeGroupID = id
    }

    func setGroupMode(_ id: UUID, _ m: MatchMode) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].mode = m
        groups[i].regions = []   // choosing a preset clears painted regions
        refreshResults()
    }

    func toggleGroupOp(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }), i > 0 else { return }
        groups[i].op = groups[i].op == .and ? .or : .and
        refreshResults()
    }

    /// Toggle a painted region on one diagram.
    func toggleRegion(group id: UUID, mask: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        if groups[i].regions.contains(mask) { groups[i].regions.remove(mask) }
        else { groups[i].regions.insert(mask) }
        refreshResults()
    }

    func clearRegions(group id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].regions = []
        refreshResults()
    }

    // MARK: Tag mutation (group-aware)

    /// Add a tag as a new circle on the ACTIVE diagram (no-op if it's already
    /// on any diagram — unless region-excluded there, which re-includes it).
    func include(_ tag: String) {
        queryExcludes.remove(tag)
        if let gi = owningGroupIndex(of: tag) {
            // re-including a region-excluded set lifts the constraint
            if regionRole(tag) == .excluded, let i = groups[gi].sets.firstIndex(of: tag) {
                let bit = 1 << i
                groups[gi].regions = Set(groups[gi].regions.flatMap { [$0, $0 | bit] })
            }
            refreshResults()
        } else {
            mutateSets(in: activeGroupIndex) { $0.append(tag) }
        }
    }

    /// Exclude a tag. If it's a circle with painted regions, constrain that
    /// diagram's regions (circle stays); otherwise move it to the excludes.
    func exclude(_ tag: String) {
        if let gi = owningGroupIndex(of: tag), !groups[gi].regions.isEmpty,
           let i = groups[gi].sets.firstIndex(of: tag) {
            let bit = 1 << i
            let constrained = Set(groups[gi].regions.map { $0 & ~bit }).filter { $0 != 0 }
            if !constrained.isEmpty {
                groups[gi].regions = constrained
                refreshResults()
                return
            }
        }
        queryExcludes.insert(tag)
        if let gi = owningGroupIndex(of: tag) {
            mutateSets(in: gi) { $0.removeAll { $0 == tag } }
        } else {
            refreshResults()
        }
    }

    /// Drop a tag from the query entirely.
    func clear(_ tag: String) {
        queryExcludes.remove(tag)
        if let gi = owningGroupIndex(of: tag) {
            mutateSets(in: gi) { $0.removeAll { $0 == tag } }
        } else {
            refreshResults()
        }
    }

    func set(_ tag: String, to s: TriState) {
        switch s {
        case .include: include(tag)
        case .exclude: exclude(tag)
        case .off: clear(tag)
        }
    }

    /// Cycle through the states the user sees: + → − → off.
    func cycle(_ tag: String) { set(tag, to: effectiveState(for: tag).next) }

    func clearQuery() {
        let g = VennGroup()
        groups = [g]
        activeGroupID = g.id
        queryExcludes = []
        applyQueryDefaults()
        refreshResults()
    }

    /// Seed the (freshly cleared) query from each tag's default stance. Mutates
    /// the query state directly — the caller triggers the single refresh.
    private func applyQueryDefaults() {
        for (tag, stance) in tagDefaults {
            // While locked, hidden tags are already filtered out of the pool;
            // skip them so their names never surface as query chips.
            if !revealed && isHiddenTag(tag) { continue }
            switch stance {
            case .include:
                if owningGroupIndex(of: tag) == nil {
                    groups[activeGroupIndex].sets.append(tag)
                }
            case .exclude:
                queryExcludes.insert(tag)
            case .off:
                break
            }
        }
    }

    // MARK: - Hidden tags & default stance (public)

    func setHidden(_ tag: String, _ hidden: Bool) {
        if hidden { hiddenTags.insert(tag) } else { hiddenTags.remove(tag) }
        UserDefaults.standard.set(Array(hiddenTags), forKey: hiddenTagsKey)
        applyVisibility()
    }

    func defaultStance(_ tag: String) -> TriState { tagDefaults[tag] ?? .off }

    func setDefault(_ tag: String, _ stance: TriState) {
        if stance == .off { tagDefaults.removeValue(forKey: tag) }
        else { tagDefaults[tag] = stance }
        UserDefaults.standard.set(tagDefaults.mapValues { $0.rawValue }, forKey: tagDefaultsKey)
    }

    // MARK: - Passcode / reveal

    var hasPasscode: Bool { UserDefaults.standard.string(forKey: passHashKey) != nil }

    func setPasscode(_ code: String) {
        guard !code.isEmpty else { return }
        let salt = Self.randomSalt()
        UserDefaults.standard.set(salt, forKey: passSaltKey)
        UserDefaults.standard.set(Self.hashPass(code, salt: salt), forKey: passHashKey)
    }

    func removePasscode() {
        UserDefaults.standard.removeObject(forKey: passSaltKey)
        UserDefaults.standard.removeObject(forKey: passHashKey)
    }

    func verifyPasscode(_ code: String) -> Bool {
        guard let salt = UserDefaults.standard.string(forKey: passSaltKey),
              let hash = UserDefaults.standard.string(forKey: passHashKey) else { return true }
        return Self.hashPass(code, salt: salt) == hash
    }

    /// Reveal hidden tags. Returns false only when a passcode is set and wrong.
    @discardableResult
    func reveal(_ code: String = "") -> Bool {
        if hasPasscode && !verifyPasscode(code) { return false }
        revealed = true
        applyVisibility()
        return true
    }

    func lock() {
        revealed = false
        applyVisibility()
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func hashPass(_ code: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + code).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func popSet() {
        let gi = activeGroupIndex
        guard !groups[gi].sets.isEmpty else { return }
        mutateSets(in: gi) { $0.removeLast() }
    }

    /// Apply a change to one diagram's sets, remapping its painted regions so
    /// overlaps survive adding/removing circles.
    private func mutateSets(in gi: Int, _ change: (inout [String]) -> Void) {
        let old = groups[gi].sets
        var new = old
        change(&new)
        groups[gi].sets = new
        groups[gi].regions = Self.remapRegions(groups[gi].regions, from: old, to: new)
        refreshResults()
    }

    /// Remap region bitmasks across a change in the ordered set list.
    /// Appending a set splits each region into with/without the new bit;
    /// removing a set drops its bit and compresses the higher bits.
    static func remapRegions(_ regions: Set<Int>, from old: [String], to new: [String]) -> Set<Int> {
        guard !regions.isEmpty else { return [] }
        var masks = regions
        // Removals: process old tags missing from new, highest bit first.
        let removed = old.enumerated().filter { !new.contains($0.element) }.map(\.offset).sorted(by: >)
        for bit in removed {
            var next = Set<Int>()
            for m in masks {
                let low = m & ((1 << bit) - 1)
                let high = (m >> (bit + 1)) << bit
                let compressed = high | low
                if compressed != 0 { next.insert(compressed) }
            }
            masks = next
        }
        // Additions: each surviving mask splits into with/without the new bit.
        let survivors = old.filter { new.contains($0) }
        let added = new.enumerated().filter { !survivors.contains($0.element) }
        for (bit, _) in added {
            var next = Set<Int>()
            for m in masks {
                // re-seat existing bits around the inserted position
                let low = m & ((1 << bit) - 1)
                let high = (m >> bit) << (bit + 1)
                let seated = high | low
                next.insert(seated)
                next.insert(seated | (1 << bit))
            }
            masks = next
        }
        return masks
    }

    /// Region counts for the Venn: membership bitmask -> item count.
    func vennData(_ tags: [String]) -> (totals: [Int], regions: [Int: Int]) {
        var regions: [Int: Int] = [:]
        for item in visibleItems {
            let mask = membershipMask(of: item, over: tags)
            if mask != 0 { regions[mask, default: 0] += 1 }
        }
        let totals = tags.map { tagCounts[$0] ?? 0 }
        return (totals, regions)
    }

    // MARK: - The single evaluator

    private func isPrefix(_ tag: String) -> Bool {
        tagCounts[tag] == nil && tagCounts.keys.contains { $0.hasPrefix(tag + "/") }
    }

    private func hasTag(_ item: FileItem, _ tag: String) -> Bool {
        if item.tagSet.contains(tag) { return true }
        return isPrefix(tag) && item.tagSet.contains { $0.hasPrefix(tag + "/") }
    }

    private func membershipMask(of item: FileItem, over tags: [String]) -> Int {
        var mask = 0
        for (i, t) in tags.enumerated() where hasTag(item, t) { mask |= (1 << i) }
        return mask
    }

    /// Evaluate THE query as sum-of-products over the diagrams: OR junctions
    /// split clauses, AND binds within a clause; an item passes when any
    /// clause passes and no exclude matches. Per diagram: painted regions
    /// gate the membership mask; otherwise the diagram's mode does.
    func refreshResults() {
        if mode == .queue { results = sortItems(queueItems); return }
        let activeGroups = groups.filter { !$0.sets.isEmpty }
        let exc = activeExcludes
        guard !activeGroups.isEmpty || !exc.isEmpty else { results = []; return }

        // Split into OR-separated clauses of AND-joined diagrams.
        var clauses: [[VennGroup]] = []
        for g in activeGroups {
            if clauses.isEmpty || g.op == .or { clauses.append([g]) }
            else { clauses[clauses.count - 1].append(g) }
        }

        func passes(_ item: FileItem, _ g: VennGroup) -> Bool {
            let mask = membershipMask(of: item, over: g.sets)
            if !g.regions.isEmpty { return g.regions.contains(mask) }
            switch g.mode {
            case .all:  return mask == (1 << g.sets.count) - 1
            case .any:  return mask != 0
            case .only: return item.tagSet == Set(g.sets)
            }
        }

        let filtered = visibleItems.filter { item in
            if !clauses.isEmpty {
                let anyClause = clauses.contains { clause in
                    clause.allSatisfy { passes(item, $0) }
                }
                if !anyClause { return false }
            }
            for e in exc where hasTag(item, e) { return false }
            return true
        }
        results = sortItems(filtered)
    }

    private func refreshVisible() {
        refreshResults()   // refreshResults handles queue mode itself
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
        guard !urls.isEmpty || wasKnown else { clear(tag); return }
        let hadState = state(for: tag)

        if !urls.isEmpty { lowSetTag(tag, on: urls, add: false) }
        if wasKnown { knownTags.remove(tag); saveKnownTags() }
        clear(tag)
        recomputeCounts(); refreshVisible()

        push("Delete “\(tag)”",
             undo: { [weak self] in
                 guard let self else { return }
                 if !urls.isEmpty { self.lowSetTag(tag, on: urls, add: true) }
                 if wasKnown { self.knownTags.insert(tag); self.saveKnownTags() }
                 if hadState != .off { self.set(tag, to: hadState) }
                 self.recomputeCounts(); self.refreshVisible()
             },
             redo: { [weak self] in
                 guard let self else { return }
                 if !urls.isEmpty { self.lowSetTag(tag, on: urls, add: false) }
                 if wasKnown { self.knownTags.remove(tag); self.saveKnownTags() }
                 self.clear(tag)
                 self.recomputeCounts(); self.refreshVisible()
             })
    }

    /// Carry a tag's query membership across a rename.
    private func swapState(_ from: String, _ to: String) {
        if let gi = owningGroupIndex(of: from),
           let idx = groups[gi].sets.firstIndex(of: from) {
            // in-place swap preserves the diagram's set order and region masks
            groups[gi].sets[idx] = to
        } else if queryExcludes.contains(from) {
            queryExcludes.remove(from)
            queryExcludes.insert(to)
        }
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
        // The query persists across Tags/Queue/Explore — same model everywhere.
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
        for item in visibleItems {
            typeCounts[item.ext.isEmpty ? "—" : item.ext, default: 0] += 1
            totalSize += item.size ?? 0
            if item.tags.isEmpty { untagged += 1 }
        }
        let byType = typeCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let topTags = tagCounts.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(15).map { ($0.key, $0.value) }
        let largest = visibleItems.max { ($0.size ?? 0) < ($1.size ?? 0) }
        return LibraryStats(
            total: visibleItems.count,
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
        hiddenTags = Set(UserDefaults.standard.stringArray(forKey: hiddenTagsKey) ?? [])
        if let raw = UserDefaults.standard.dictionary(forKey: tagDefaultsKey) as? [String: Int] {
            tagDefaults = raw.compactMapValues { TriState(rawValue: $0) }
        }
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
