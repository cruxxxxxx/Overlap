import AppKit
import Combine
import Foundation

/// Drives the Explore page: draws batches from the search plugin's index, feeds
/// likes and viewing into the taste profile, keeps the small state file.
@MainActor
final class ExploreModel: ObservableObject {
    enum Status { case ok, noPlugin, noIndex, exhausted, noMatches }

    static let batchSize = 24
    static let maxEvents = 500
    static let maxSeen = 5000
    static let dwellSeconds: UInt64 = 4
    private static let candidatesPerTaste = 40

    @Published private(set) var profile = TasteProfile()
    @Published private(set) var events: [TasteEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var status = Status.ok
    @Published private(set) var batches: [[URL]] = []
    @Published private(set) var batchIndex = 0
    @Published private(set) var showingLiked = false
    @Published private(set) var focusedTaste: UUID?
    @Published private(set) var lastLess: LessUndo?
    /// Familiar ↔ surprising, 0...1; takes effect from the next batch.
    @Published var surprise: Double = UserDefaults.standard.object(forKey: "exploreSurprise") as? Double
        ?? ExploreBatch.Mix.standard.surprise {
        didSet { UserDefaults.standard.set(surprise, forKey: "exploreSurprise") }
    }

    struct LessUndo {
        let eventIDs: [UUID]
        let urls: [URL]
        let batchIndex: Int
        let batchBefore: [URL]
    }

    private struct SavedState: Codable {
        var model: String?
        var events: [TasteEvent]
        var seen: [String]
    }

    private weak var store: TagStore?
    private var model: String?
    private var seen: [String] = []
    private var vectors: [String: [Float]] = [:]
    private var drawToken = UUID()
    private var dwellTask: Task<Void, Never>?
    private var scope: URL?
    private var filterSignature: String?

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Overlap/explore-profile.json")
    }

    func attach(to store: TagStore) {
        guard self.store == nil else {
            return
        }
        self.store = store
        load()
        store.onPrivacyChange = { [weak self] in
            self?.dropWithheldFiles()
        }
    }

    // MARK: Page

    var likedEvents: [TasteEvent] {
        events.filter { $0.signal == .like }.reversed()
    }

    var currentBatch: [URL] {
        batches.indices.contains(batchIndex) ? batches[batchIndex] : []
    }

    var isColdStart: Bool { profile.tastes.isEmpty }

    /// The page came on screen: show what was there, or the first batch.
    func enter() {
        dropWithheldFiles()
        if let store, scope != store.scopeURL {
            scope = store.scopeURL
            batches = []
            batchIndex = 0
        }
        let filterMoved = filterSignature != nil && filterSignature != store?.exploreFilterSignature
        filterSignature = store?.exploreFilterSignature
        if showingLiked {
            showLiked()
        } else if currentBatch.isEmpty || filterMoved || status == .noMatches || status == .exhausted {
            draw()
        } else {
            store?.showExplore(currentBatch)
        }
    }

    /// The tags changed: the next batch follows them right away. What's behind
    /// stays reachable with Back.
    func filterChanged() {
        guard let store, filterSignature != store.exploreFilterSignature else {
            return
        }
        filterSignature = store.exploreFilterSignature
        showingLiked = false
        draw()
    }

    func next() {
        showingLiked = false
        if batchIndex + 1 < batches.count {
            batchIndex += 1
            show(currentBatch)
        } else {
            draw()
        }
    }

    /// Step to the next image; past the last one, on to the next batch.
    func advance() {
        guard let store, !loading else {
            return
        }
        if let last = store.results.last, !store.selection.contains(last.id) {
            store.moveSelection(dx: 1, dy: 0)
        } else if !showingLiked {
            next()
        }
    }

    func back() {
        showingLiked = false
        guard batchIndex > 0 else {
            return
        }
        batchIndex -= 1
        show(currentBatch)
    }

    func showLiked() {
        showingLiked = true
        store?.showExplore(likedEvents.map { URL(fileURLWithPath: $0.path) })
    }

    func leaveLiked() {
        showingLiked = false
        show(currentBatch)
    }

    /// The next batch comes only from this taste; again to go back to all.
    func focus(on taste: UUID) {
        focusedTaste = focusedTaste == taste ? nil : taste
        showingLiked = false
        batchIndex = max(0, batches.count - 1)
        draw()
    }

    private func show(_ urls: [URL]) {
        store?.showExplore(urls)
        select(at: 0)
    }

    /// Keep a selection so the keys always have an image to act on.
    private func select(at index: Int) {
        guard let store, store.mode == .explore, !store.results.isEmpty else {
            return
        }
        let id = store.results[min(index, store.results.count - 1)].id
        store.selection = [id]
        store.selectionAnchor = id
        store.scrollTarget = id
    }

    // MARK: Drawing

    private func draw(afterRecycling recycled: Bool = false) {
        guard let store else {
            return
        }
        guard store.exploreAvailable else {
            status = .noPlugin
            return
        }
        let token = UUID()
        drawToken = token
        let within = store.explorePaths
        let filtered = !store.exploreFilterSignature.isEmpty
        if within.isEmpty {
            drawToken = UUID()
            loading = false
            status = filtered ? .noMatches : .exhausted
            store.showExplore([])
            return
        }
        loading = true
        let tastes = focusedTaste.flatMap { id in profile.tastes.first { $0.id == id } }.map { [$0] } ?? profile.tastes
        let excluded = Array(Set(recycled ? [] : seen).union(events.filter { $0.signal == .like || $0.signal == .lessLikeThis }.map(\.path)))
        // Over-ask: hidden files can't be named to the plugin, so they're
        // dropped from what comes back.
        let query = ExploreQuery(tastes: tastes.map { TasteProfile.data($0.vector) },
                                 avoid: profile.avoids.map { TasteProfile.data($0.vector) },
                                 exclude: excluded, roots: store.exploreRoots,
                                 perTaste: Self.candidatesPerTaste,
                                 random: Self.batchSize * 3,
                                 within: within)
        let weights = focusedTaste == nil ? tastes.map(\.weight) : tastes.map { _ in 1 }
        Task { [weak self] in
            let outcome = await store.runExploreQuery(query)
            guard let self, self.drawToken == token else {
                return
            }
            self.loading = false
            self.receive(outcome, weights: weights, recycled: recycled, filtered: filtered)
        }
    }

    private func receive(_ outcome: SearchEngine.ExploreOutcome, weights: [Float], recycled: Bool, filtered: Bool) {
        guard let store else {
            return
        }
        guard outcome.ranPlugin else {
            status = .noPlugin
            return
        }
        guard let result = outcome.result, (outcome.indexedCount ?? 0) > 0 else {
            status = .noIndex
            return
        }
        adopt(model: result.model)
        let urls = Array(Set(result.candidates.map(\.path))).map { URL(fileURLWithPath: $0) }
        let allowed = Set(store.shareableForSource(urls).allowed.map(\.path))
        let fm = FileManager.default
        let candidates = result.candidates.compactMap { wire -> ExploreBatch.Candidate? in
            guard allowed.contains(wire.path), fm.fileExists(atPath: wire.path) else {
                return nil
            }
            return ExploreBatch.Candidate(path: wire.path, score: Float(wire.score), taste: wire.taste,
                                          vector: TasteProfile.vector(wire.vector))
        }
        var rng = SystemRandomNumberGenerator()
        let paths = ExploreBatch.compose(candidates: candidates, weights: weights, size: Self.batchSize,
                                         mix: ExploreBatch.Mix(surprise: surprise), using: &rng)
        guard !paths.isEmpty else {
            if !recycled && !seen.isEmpty {
                // Everything's been shown: start the rotation over. A filter's
                // few files repeat without resetting the whole library's.
                if !filtered {
                    seen = []
                }
                draw(afterRecycling: true)
            } else {
                status = filtered ? .noMatches : .exhausted
                store.showExplore([])
            }
            return
        }
        status = .ok
        for candidate in candidates where paths.contains(candidate.path) {
            vectors[candidate.path] = candidate.vector
        }
        let batch = paths.map { URL(fileURLWithPath: $0) }
        if !currentBatch.isEmpty {
            batchIndex = batches.count
        }
        if batchIndex < batches.count {
            batches[batchIndex] = batch
        } else {
            batches.append(batch)
        }
        seen.append(contentsOf: paths)
        if seen.count > Self.maxSeen {
            seen.removeFirst(seen.count - Self.maxSeen)
        }
        save()
        show(batch)
    }

    /// Vectors from another encoder don't compare, so a variant switch starts over.
    private func adopt(model newModel: String) {
        if let model, model != newModel {
            events = []
            refold()
        }
        model = newModel
    }

    // MARK: Signals

    func isLiked(_ url: URL) -> Bool {
        events.contains { $0.path == url.path && $0.signal == .like }
    }

    /// Like every target, or unlike them all when they're all liked already.
    func toggleLike(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        if urls.allSatisfy(isLiked) {
            let paths = Set(urls.map(\.path))
            events.removeAll { $0.signal == .like && paths.contains($0.path) }
        } else {
            for url in urls where !isLiked(url) {
                events.removeAll { $0.path == url.path && $0.signal == .lessLikeThis }
                record(.like, url)
            }
        }
        changed()
        if showingLiked {
            showLiked()
        }
    }

    func lessLikeThis(_ urls: [URL]) {
        guard !urls.isEmpty, let store else {
            return
        }
        let batchBefore = currentBatch
        let paths = Set(urls.map(\.path))
        let position = store.results.firstIndex { paths.contains($0.id) }
        events.removeAll { $0.signal == .like && paths.contains($0.path) }
        let recorded = urls.compactMap { record(.lessLikeThis, $0) }
        if batches.indices.contains(batchIndex) {
            batches[batchIndex].removeAll { paths.contains($0.path) }
        }
        lastLess = LessUndo(eventIDs: recorded, urls: urls, batchIndex: batchIndex, batchBefore: batchBefore)
        changed()
        store.showExplore(showingLiked ? likedEvents.map { URL(fileURLWithPath: $0.path) } : currentBatch)
        if let position {
            select(at: position)
        }
    }

    func undoLess() {
        guard let undo = lastLess else {
            return
        }
        events.removeAll { undo.eventIDs.contains($0.id) }
        if batches.indices.contains(undo.batchIndex) {
            batches[undo.batchIndex] = undo.batchBefore
        }
        lastLess = nil
        changed()
        if !showingLiked {
            store?.showExplore(currentBatch)
        }
    }

    /// Quick Look or a double-click: stronger than a glance, once per image.
    func noteOpened(_ urls: [URL]) {
        var any = false
        for url in urls where !hasEvent(url, .opened) {
            any = record(.opened, url) != nil || any
        }
        if any {
            changed()
        }
    }

    /// A single image kept selected for a few seconds counts as looked at.
    func noteSelection(_ selection: Set<String>) {
        dwellTask?.cancel()
        guard selection.count == 1, let path = selection.first, vectors[path] != nil else {
            return
        }
        let url = URL(fileURLWithPath: path)
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dwellSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, NSApp.isActive, !self.hasEvent(url, .viewed) else {
                return
            }
            if self.record(.viewed, url) != nil {
                self.changed()
            }
        }
    }

    private func hasEvent(_ url: URL, _ signal: TasteSignal) -> Bool {
        events.contains { $0.path == url.path && $0.signal == signal }
    }

    @discardableResult
    private func record(_ signal: TasteSignal, _ url: URL) -> UUID? {
        guard let vector = vectors[url.path] ?? events.last(where: { $0.path == url.path }).map({ TasteProfile.vector($0.vector) }) else {
            return nil
        }
        let event = TasteEvent(path: url.path, signal: signal, date: Date(), vector: TasteProfile.data(vector))
        events.append(event)
        return event.id
    }

    // MARK: Editing the profile

    func forget(_ taste: TasteCentroid) {
        events.removeAll { taste.eventIDs.contains($0.id) }
        if focusedTaste == taste.id {
            focusedTaste = nil
        }
        changed()
    }

    func reset() {
        events = []
        seen = []
        focusedTaste = nil
        lastLess = nil
        showingLiked = false
        batches = []
        batchIndex = 0
        changed()
        draw()
    }

    private func changed() {
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        refold()
        save()
    }

    private func refold() {
        profile = TasteProfile.fold(events)
        if let focusedTaste, !profile.tastes.contains(where: { $0.id == focusedTaste }) {
            self.focusedTaste = nil
        }
    }

    /// A file that became hidden leaves the log, so its embedding leaves the
    /// profile on the refold. Runs on every vault reconcile: cheap when clean.
    private func dropWithheldFiles() {
        guard let store else {
            return
        }
        let withheld = store.pathsWithheldFromPlugins()
        guard !withheld.isEmpty else {
            return
        }
        let eventCount = events.count, seenCount = seen.count
        events.removeAll { withheld.contains($0.path) }
        seen.removeAll { withheld.contains($0) }
        for path in withheld {
            vectors.removeValue(forKey: path)
        }
        for i in batches.indices {
            batches[i].removeAll { withheld.contains($0.path) }
        }
        if events.count != eventCount || seen.count != seenCount {
            changed()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return
        }
        model = state.model
        events = state.events
        seen = state.seen
        refold()
    }

    private func save() {
        guard let url = Self.fileURL else {
            return
        }
        let state = SavedState(model: model, events: events, seen: seen)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
