import Foundation
import AppKit
import Combine
import CryptoKit

/// One file placed on a mood board. `path` is the file's *logical* path — where
/// it lives outside the vault — so a tile survives the file moving into or out
/// of the vault (see `VaultDisk.originalPath`).
struct BoardItem: Identifiable, Codable, Equatable {
    var path: String
    var frame: CGRect          // canvas units (points at zoom 1)
    var z: Int
    var bookmark: Data?        // re-finds a file that was moved or renamed

    var id: String { path }
}

/// A free-form canvas of thumbnails. A snapshot that can be refreshed: it
/// remembers the query it came from (`source`), and "Refresh from Query" adds
/// new matches without touching placed tiles or re-adding `dismissed` ones.
struct MoodBoard: Identifiable, Codable {
    var id = UUID()
    var name: String
    var created = Date()
    var source: SavedQuery?
    var items: [BoardItem] = []
    var dismissed: Set<String> = []
    var zoom: Double?
    /// Colors collected for this board. Optional so older boards still decode.
    var palette: [PaletteSwatch]?
    /// Notes, labels and boxes. Optional so older boards still decode.
    var elements: [BoardElement]?

    var maxZ: Int { items.map(\.z).max() ?? 0 }

    /// Bounding box of every tile and element; nil when empty.
    var bounds: CGRect? {
        let frames = items.map(\.frame) + (elements ?? []).map(\.frame)
        guard let first = frames.first else {
            return nil
        }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}

/// The encrypted half of a board: tiles and dismissals for hidden files, plus
/// the whole board when its source query names a hidden tag.
private struct PrivateBoardPart: Codable {
    var board: MoodBoard?          // set only for a fully private board
    var items: [BoardItem] = []
    var dismissed: Set<String> = []
}

extension VaultDisk {
    /// Where a vault file came from (the inverse of `vaultURL(forOriginal:)`);
    /// any other path is returned unchanged.
    static func originalPath(of path: String) -> String {
        guard contains(path) else {
            return path
        }
        return "/" + path.dropFirst(filesRoot.path.count + 1)
    }

    /// Where a board's logical path is right now: the vault copy when it's
    /// attached and holds the file, otherwise the logical path itself.
    static func resolvedURL(forLogicalPath path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return url
        }
        let vaultURL = vaultURL(forOriginal: url)
        if isAttached && fm.fileExists(atPath: vaultURL.path) {
            return vaultURL
        }
        return url
    }
}

/// Owns every mood board and its persistence:
///  - `Boards/<id>.json` — the board minus anything private (plain JSON).
///  - `Boards/<id>.private` — tiles for hidden files, AES-GCM sealed with a
///    key kept in the keychain. Read on reveal, dropped from memory on lock,
///    so a locked app neither shows nor holds them.
@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var boards: [MoodBoard] = []

    private weak var tags: TagStore?
    private var revealSubscription: AnyCancellable?
    private var dirty: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    /// Each board's own undo history. Owned here, not taken from SwiftUI's
    /// environment, so ⌘Z doesn't depend on how the window's responder chain
    /// happens to be wired.
    private var undoManagers: [UUID: UndoManager] = [:]
    /// Which board each open board window shows, for Edit › Undo.
    private let windowBoards = NSMapTable<NSWindow, NSUUID>.weakToStrongObjects()

    private static let keyAccount = "board-key"

    // MARK: - Lifecycle

    /// Bind to the tag store (idempotent; every window calls it on appear).
    func attach(to store: TagStore) {
        guard tags == nil else {
            return
        }
        tags = store
        loadPublic()
        if store.revealed {
            loadPrivate()
        }
        revealSubscription = store.$revealed.removeDuplicates().sink { [weak self] revealed in
            // @Published fires before the value lands: on lock the vault is
            // still attached here, so private tiles can still be told apart.
            guard let self else {
                return
            }
            if revealed {
                DispatchQueue.main.async {
                    self.loadPrivate()
                    self.saveAll()   // re-split: files may have become hidden
                }
            } else {
                self.saveAll()
                self.dropPrivate()
                self.clearUndoHistory()
            }
        }
    }

    func board(_ id: UUID) -> MoodBoard? {
        boards.first { $0.id == id }
    }

    // MARK: - Mutation

    /// Replace a board wholesale, registering the previous state for undo.
    /// Undoing goes through here too, so redo comes for free.
    func replace(_ board: MoodBoard, undo: UndoManager?, actionName: String?) {
        guard let i = boards.firstIndex(where: { $0.id == board.id }) else {
            return
        }
        let previous = boards[i]
        boards[i] = board
        scheduleSave(board.id)
        guard let undo, let actionName else {
            return
        }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                // Zoom is a view setting, not an edit: keep whatever it is now.
                var restored = previous
                restored.zoom = target.board(previous.id)?.zoom
                target.replace(restored, undo: undo, actionName: actionName)
            }
        }
        undo.setActionName(actionName)
    }

    /// Undo steps hold whole-board snapshots, private tiles included, so
    /// locking forgets them all.
    private func clearUndoHistory() {
        for manager in undoManagers.values {
            manager.removeAllActions()
        }
    }

    func undoManager(for id: UUID) -> UndoManager {
        if let manager = undoManagers[id] {
            return manager
        }
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        undoManagers[id] = manager
        return manager
    }

    func register(window: NSWindow, for id: UUID) {
        windowBoards.setObject(id as NSUUID, forKey: window)
    }

    /// The board shown in `window`, if it's a board window.
    func boardID(in window: NSWindow?) -> UUID? {
        guard let window else {
            return nil
        }
        return windowBoards.object(forKey: window) as UUID?
    }

    func mutate(_ id: UUID, undo: UndoManager? = nil, actionName: String? = nil,
                _ change: (inout MoodBoard) -> Void) {
        guard var board = board(id) else {
            return
        }
        change(&board)
        replace(board, undo: undo, actionName: actionName)
    }

    func createBoard(name: String, source: SavedQuery?, items: [BoardItem]) -> UUID {
        let board = MoodBoard(name: name, source: source, items: items)
        boards.append(board)
        scheduleSave(board.id)
        return board.id
    }

    func rename(_ id: UUID, to name: String, undo: UndoManager? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        mutate(id, undo: undo, actionName: "Rename Board") { $0.name = trimmed }
    }

    func delete(_ id: UUID) {
        boards.removeAll { $0.id == id }
        dirty.remove(id)
        undoManagers.removeValue(forKey: id)?.removeAllActions()
        let fm = FileManager.default
        try? fm.removeItem(at: publicURL(id))
        try? fm.removeItem(at: privateURL(id))
    }

    /// Lay `paths` out as a masonry block below everything already placed.
    /// Skips paths already on the board. Aspect ratios are read off-main.
    func addFiles(_ paths: [String], to id: UUID, at point: CGPoint? = nil,
                  undo: UndoManager?) async {
        guard let existing = board(id) else {
            return
        }
        let onBoard = Set(existing.items.map(\.path))
        let fresh = paths.filter { !onBoard.contains($0) }
        guard !fresh.isEmpty else {
            return
        }
        let aspects = await BoardLayout.aspectRatios(fresh)
        mutate(id, undo: undo, actionName: "Add to Board") { board in
            let origin: CGPoint
            if let point {
                origin = point
            } else if let bounds = board.bounds {
                origin = CGPoint(x: BoardLayout.margin, y: bounds.maxY + BoardLayout.gap * 3)
            } else {
                origin = CGPoint(x: BoardLayout.margin, y: BoardLayout.margin)
            }
            let columns = point == nil ? BoardLayout.columns(for: fresh.count) : min(fresh.count, 4)
            let frames = BoardLayout.masonry(aspects, origin: origin, columns: columns)
            var z = board.maxZ
            for (path, frame) in zip(fresh, frames) {
                z += 1
                board.items.append(BoardItem(path: path, frame: frame, z: z,
                                             bookmark: Self.bookmark(for: path)))
                board.dismissed.remove(path)
            }
        }
    }

    nonisolated static func bookmark(for path: String) -> Data? {
        guard !VaultDisk.contains(path) else {
            return nil
        }
        return try? URL(fileURLWithPath: path).bookmarkData()
    }

    // MARK: - Persistence

    private static var boardsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Overlap/Boards", isDirectory: true)
    }

    private func publicURL(_ id: UUID) -> URL {
        Self.boardsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private func privateURL(_ id: UUID) -> URL {
        Self.boardsDir.appendingPathComponent("\(id.uuidString).private")
    }

    private func scheduleSave(_ id: UUID) {
        dirty.insert(id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.flush()
        }
    }

    /// Write every board with pending changes now.
    func flush() {
        let ids = dirty
        dirty = []
        for id in ids {
            if let board = board(id) {
                save(board)
            }
        }
    }

    private func saveAll() {
        dirty = []
        boards.forEach(save)
    }

    /// Split into public + private parts and write both. While locked only
    /// public tiles are in memory, so the private file is left as it is.
    private func save(_ board: MoodBoard) {
        guard let tags else {
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.boardsDir, withIntermediateDirectories: true)
        let fullyPrivate = board.source.map { tags.isPrivateQuery($0) } ?? false
        // While locked, memory holds only what was public at lock time; never
        // re-split then, or a tile that turned private would be lost.
        let hidden = tags.revealed
            ? tags.privatePaths(among: board.items.map(\.path) + Array(board.dismissed))
            : []

        var publicPart = board
        publicPart.items = board.items.filter { !hidden.contains($0.path) }
        publicPart.dismissed = board.dismissed.subtracting(hidden)
        var privatePart = PrivateBoardPart(
            items: board.items.filter { hidden.contains($0.path) },
            dismissed: board.dismissed.intersection(hidden))
        if fullyPrivate {
            privatePart = PrivateBoardPart(board: board)
        }

        if fullyPrivate {
            try? fm.removeItem(at: publicURL(board.id))
        } else {
            write(publicPart, to: publicURL(board.id))
        }
        guard tags.revealed else {
            return
        }
        if privatePart.board == nil && privatePart.items.isEmpty && privatePart.dismissed.isEmpty {
            try? fm.removeItem(at: privateURL(board.id))
        } else if let data = try? JSONEncoder().encode(privatePart),
                  let sealed = try? AES.GCM.seal(data, using: Self.key()).combined {
            try? sealed.write(to: privateURL(board.id), options: .atomic)
        }
    }

    private func write(_ board: MoodBoard, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(board) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadPublic() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.boardsDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [MoodBoard] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               var board = try? dec.decode(MoodBoard.self, from: data) {
                Self.relinkMovedFiles(&board)
                loaded.append(board)
            }
        }
        boards = loaded.sorted { $0.created < $1.created }
    }

    /// Merge each board's sealed half back in.
    private func loadPrivate() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.boardsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "private" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let sealed = try? Data(contentsOf: url),
                  let box = try? AES.GCM.SealedBox(combined: sealed),
                  let data = try? AES.GCM.open(box, using: Self.key()),
                  let part = try? JSONDecoder().decode(PrivateBoardPart.self, from: data) else {
                continue
            }
            if let full = part.board {
                boards.removeAll { $0.id == id }
                boards.append(full)
            } else if let i = boards.firstIndex(where: { $0.id == id }) {
                let present = Set(boards[i].items.map(\.path))
                boards[i].items += part.items.filter { !present.contains($0.path) }
                boards[i].dismissed.formUnion(part.dismissed)
            }
        }
        boards.sort { $0.created < $1.created }
    }

    /// On lock: forget everything private. Fully private boards disappear
    /// (their windows show "unavailable"); others lose their hidden tiles.
    private func dropPrivate() {
        guard let tags else {
            return
        }
        boards.removeAll { $0.source.map { tags.isPrivateQuery($0) } ?? false }
        for i in boards.indices {
            let hidden = tags.privatePaths(among: boards[i].items.map(\.path) + Array(boards[i].dismissed))
            boards[i].items.removeAll { hidden.contains($0.path) }
            boards[i].dismissed.subtract(hidden)
        }
    }

    /// A tile whose file is gone but whose bookmark still resolves follows it.
    private static func relinkMovedFiles(_ board: inout MoodBoard) {
        let fm = FileManager.default
        for i in board.items.indices where !fm.fileExists(atPath: board.items[i].path) {
            guard let data = board.items[i].bookmark else {
                continue
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
                  fm.fileExists(atPath: url.path),
                  !board.items.contains(where: { $0.path == url.path }) else {
                continue
            }
            board.items[i].path = url.path
            board.items[i].bookmark = try? url.bookmarkData()
        }
    }

    /// The board encryption key, created on first use.
    private static func key() -> SymmetricKey {
        if let data = Keychain.read(keyAccount), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        Keychain.write(key.withUnsafeBytes { Data($0) }, account: keyAccount)
        return key
    }
}

// MARK: - Creating boards from queries

extension BoardStore {
    /// Results above this ask before landing on a board.
    static let largeBoardThreshold = 500

    /// A new board holding the live results, remembering the query that made
    /// them. Returns nil when there is nothing to place or the user cancels.
    func createFromResults(_ store: TagStore, name: String? = nil,
                           source: SavedQuery? = nil) async -> UUID? {
        var paths = store.results
            .filter { $0.kind != .folder }
            .map { VaultDisk.originalPath(of: $0.id) }
        guard !paths.isEmpty else {
            return nil
        }
        if paths.count > Self.largeBoardThreshold {
            guard let limit = Self.askLargeBoardLimit(paths.count) else {
                return nil
            }
            paths = Array(paths.prefix(limit))
        }
        let description = store.queryDescription
        let query = source ?? (store.mode == .queue
            ? nil
            : store.currentQuerySnapshot(name: description, includeTypes: true))
        let isPrivate = query.map { store.isPrivateQuery($0) } ?? false
        let boardName = name ?? (isPrivate ? "Private Board" : description)
        let id = createBoard(name: boardName, source: query, items: [])
        await addFiles(paths, to: id, undo: nil)
        return id
    }

    /// Run a saved query in the main window, wait for any search to finish,
    /// then board its results.
    func createFromQuery(_ query: SavedQuery, store: TagStore) async -> UUID? {
        store.applyQuery(query)
        await store.waitForSearch()
        return await createFromResults(store, name: query.name, source: query)
    }

    private static func askLargeBoardLimit(_ count: Int) -> Int? {
        let alert = NSAlert()
        alert.messageText = "Put \(count) files on a board?"
        alert.informativeText = "Big boards get slow to arrange. You can start with the first \(largeBoardThreshold) and refresh later."
        alert.addButton(withTitle: "First \(largeBoardThreshold)")
        alert.addButton(withTitle: "All \(count)")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return largeBoardThreshold
        case .alertSecondButtonReturn:
            return count
        default:
            return nil
        }
    }
}
