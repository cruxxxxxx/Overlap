import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Coordinate-space names shared by the canvas and its tiles.
enum BoardCanvas {
    static let space = "boardCanvas"
    static let scroll = "boardScroll"
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4
}

/// Window content for one board (`WindowGroup(for: UUID.self)`). A board that
/// is gone — deleted, or private and the app just locked — shows a stub.
struct BoardWindow: View {
    let boardID: UUID?
    @EnvironmentObject var boards: BoardStore

    var body: some View {
        if let boardID, boards.board(boardID) != nil {
            MoodBoardView(boardID: boardID)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("This board isn't available.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The mood board canvas: tiles placed freely, moved by dragging, resized by
/// their corner handle, removed with ⌫. Zoom with a pinch or ⌘= / ⌘− / ⌘0.
struct MoodBoardView: View {
    let boardID: UUID
    @EnvironmentObject var boards: BoardStore
    private var undoManager: UndoManager { boards.undoManager(for: boardID) }
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var selection: Set<String> = []
    @State private var selectedElements: Set<UUID> = []
    @State private var moveDelta: CGSize?            // canvas units, applies to `moving`
    @State private var moving: (paths: Set<String>, elements: Set<UUID>)?
    @State private var resizing: (path: String, size: CGSize)?
    @State private var resizingElement: (id: UUID, size: CGSize)?
    @State private var editingElement: UUID?
    @State private var marquee: (start: CGPoint, end: CGPoint)?   // canvas units
    @State private var marqueeBase: (paths: Set<String>, elements: Set<UUID>) = ([], [])
    @State private var scrollOrigin: CGPoint = .zero  // content origin in the scroll view
    @State private var viewport: CGSize = .zero
    @State private var hiddenWhileLocked: Set<String> = []
    @State private var refreshing = false
    @State private var exportStatus: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var syncingSource = false
    @State private var sendCandidates: [URL] = []
    @State private var confirmingSend = false
    @AppStorage("boardShowsPalette") private var showsPalette = true
    @AppStorage("boardSnapToGrid") private var snapToGrid = false

    private var board: MoodBoard? { boards.board(boardID) }

    /// Tiles the user may see: while locked, anything that turned private
    /// since the board was last split stays off screen.
    private var visibleItems: [BoardItem] {
        guard let board else {
            return []
        }
        if store.revealed || hiddenWhileLocked.isEmpty {
            return board.items
        }
        return board.items.filter { !hiddenWhileLocked.contains($0.path) }
    }

    private var visibleElements: [BoardElement] { board?.elementList ?? [] }

    /// Everything currently selected, tiles and elements alike.
    private var selectedKeys: [BoardObjectKey] {
        selection.map { .item($0) } + selectedElements.map { .element($0) }
    }

    private var allFrames: [CGRect] {
        visibleItems.map(\.frame) + visibleElements.map(\.frame)
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasArea
            if showsPalette {
                Divider()
                PalettePanel(boardID: boardID,
                             selectedPath: selection.count == 1 && selectedElements.isEmpty
                                 ? selection.first : nil)
            }
        }
        .navigationTitle(board?.name ?? "Board")
        .navigationSubtitle(subtitle)
        .task(id: "\(store.revealed)|\(board?.items.count ?? 0)") {
            refreshLockedFilter()
        }
        .alert("Rename Board", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { boards.rename(boardID, to: renameText, undo: undoManager) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this board?", isPresented: $confirmingDelete) {
            Button("Delete Board", role: .destructive) {
                boards.delete(boardID)
                dismiss()
            }
        } message: {
            Text("Only the board is deleted. Its files stay where they are.")
        }
        .confirmationDialog(sendPrompt, isPresented: $confirmingSend) {
            Button("Send \(sendCandidates.count)") { sendCandidatesToSource() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(sendWarning)
        }
        .onChange(of: sources.finishedPull) { event in
            guard let event, let link = sourceLink, event.linkID == link.id else {
                return
            }
            foldInSource(link, offerSend: syncingSource)
            syncingSource = false
        }
    }

    private var canvasArea: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    canvas
                }
                .coordinateSpace(name: BoardCanvas.scroll)
                .background(Color(nsColor: .underPageBackgroundColor))
                .simultaneousGesture(pinchGesture)
                .onAppear {
                    viewport = outer.size
                    // SwiftUI hands a new window's focus to its first text
                    // field; start on the canvas instead.
                    DispatchQueue.main.async {
                        focusCanvas()
                    }
                    if let saved = board?.zoom {
                        zoom = CGFloat(saved)
                    } else {
                        fit(proxy)
                    }
                }
                .onChange(of: outer.size) { viewport = $0 }
                .toolbar { toolbar(proxy) }
                .background(keyHandler)
            }
        }
    }

    private var subtitle: String {
        if let exportStatus {
            return exportStatus
        }
        if refreshing {
            return "Refreshing…"
        }
        if syncingSource, let activity = sources.activity {
            return activity
        }
        let count = visibleItems.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    // MARK: - Canvas

    private var contentSize: CGSize {
        let bounds = allFrames.reduce(CGRect.zero) { $0.union($1) }
        let room: CGFloat = 400   // space to drag past the last tile
        return CGSize(width: max(viewport.width, (bounds.maxX + room) * zoom),
                      height: max(viewport.height, (bounds.maxY + room) * zoom))
    }

    /// The part of the canvas worth drawing (canvas units), padded so tiles
    /// are ready before they scroll in. Unbounded for small boards.
    private var drawRect: CGRect {
        guard visibleItems.count > 150, viewport != .zero else {
            return .infinite
        }
        let rect = CGRect(x: -scrollOrigin.x / zoom, y: -scrollOrigin.y / zoom,
                          width: viewport.width / zoom, height: viewport.height / zoom)
        return rect.insetBy(dx: -rect.width * 0.5, dy: -rect.height * 0.5)
    }

    private var canvas: some View {
        let size = contentSize
        let area = drawRect
        let ordered = visibleItems
            .filter { area.intersects(displayFrame($0)) }
            .sorted { $0.z < $1.z }
        let elements = visibleElements.sorted { $0.z < $1.z }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(marqueeGesture)
                .onTapGesture {
                    focusCanvas()
                    clearSelection()
                }
            Color.clear.frame(width: 1, height: 1).id("origin")
            if snapToGrid {
                gridLayer
            }
            ForEach(elements.filter { $0.kind == .box }) { element in
                elementView(element)
            }
            ForEach(ordered) { item in
                tile(item)
            }
            ForEach(elements.filter { $0.kind != .box }) { element in
                elementView(element)
            }
            if let rect = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                    .frame(width: rect.width * zoom, height: rect.height * zoom)
                    .offset(x: rect.minX * zoom, y: rect.minY * zoom)
                    .allowsHitTesting(false)
            }
            if visibleItems.isEmpty && visibleElements.isEmpty {
                emptyHint
                    .frame(width: viewport.width, height: viewport.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: BoardCanvas.space)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ScrollOriginKey.self,
                                   value: geo.frame(in: .named(BoardCanvas.scroll)).origin)
        })
        .onPreferenceChange(ScrollOriginKey.self) { scrollOrigin = $0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
            dropFiles(providers, at: location)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Drag files here from Overlap or Finder")
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ item: BoardItem) -> some View {
        let frame = displayFrame(item)
        let lifted = moveDelta != nil && moving?.paths.contains(item.path) == true
        return BoardTile(item: item,
                         size: CGSize(width: frame.width * zoom, height: frame.height * zoom),
                         selected: selection.contains(item.path),
                         hideIfMissing: !store.revealed && store.vaultEnabled,
                         onResize: { translation, ended in resize(item, by: translation, ended: ended) })
            .offset(x: frame.minX * zoom, y: frame.minY * zoom)
            .zIndex(Double(item.z) + (lifted ? 1_000_000 : 0))
            .gesture(moveGesture(.item(item.path)))
            .simultaneousGesture(TapGesture(count: 2).onEnded { quickLook(item) })
            .simultaneousGesture(TapGesture().onEnded { tap(item) })
            .contextMenu { tileMenu(item) }
    }

    /// Where a tile is drawn right now: its saved frame plus any move or
    /// resize in progress.
    private func displayFrame(_ item: BoardItem) -> CGRect {
        var frame = item.frame
        if let moveDelta, moving?.paths.contains(item.path) == true {
            frame = frame.offsetBy(dx: moveDelta.width, dy: moveDelta.height)
        }
        if let resizing, resizing.path == item.path {
            frame.size = resizing.size
        }
        return frame
    }

    private func displayFrame(_ element: BoardElement) -> CGRect {
        var frame = element.frame
        if let moveDelta, moving?.elements.contains(element.id) == true {
            frame = frame.offsetBy(dx: moveDelta.width, dy: moveDelta.height)
        }
        if let resizingElement, resizingElement.id == element.id {
            frame.size = resizingElement.size
        }
        return frame
    }

    /// Boxes sit under every tile; notes and labels over them.
    private func elementView(_ element: BoardElement) -> some View {
        let frame = displayFrame(element)
        let layer: Double = element.kind == .box ? -1_000_000 : 3_000_000
        let isEditing = editingElement == element.id
        return BoardElementView(element: element,
                                size: CGSize(width: frame.width * zoom, height: frame.height * zoom),
                                zoom: zoom,
                                selected: selectedElements.contains(element.id),
                                editing: isEditing,
                                onCommit: { commitText(element.id, $0) },
                                onResize: { translation, ended in
                                    resizeElement(element, by: translation, ended: ended)
                                })
            .offset(x: frame.minX * zoom, y: frame.minY * zoom)
            .zIndex(layer + Double(element.z))
            .gesture(moveGesture(.element(element.id)), including: isEditing ? .subviews : .all)
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditing(element) },
                                 including: isEditing ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { tapElement(element) },
                                 including: isEditing ? .subviews : .all)
            .contextMenu { elementMenu(element) }
    }

    /// Dots-free line grid over the visible part of the canvas only.
    private var gridLayer: some View {
        let step = BoardArrange.gridStep * zoom
        let origin = CGPoint(x: -scrollOrigin.x, y: -scrollOrigin.y)
        return Canvas { context, size in
            guard step >= 6 else {
                return
            }
            var path = Path()
            var x = (origin.x / step).rounded(.up) * step - origin.x
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = (origin.y / step).rounded(.up) * step - origin.y
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
        }
        .frame(width: viewport.width, height: viewport.height)
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    /// Drags whatever is selected, `key` included, plus the contents of any
    /// selected box. With snapping on, the grabbed object lands on the grid.
    private func moveGesture(_ key: BoardObjectKey) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardCanvas.space))
            .onChanged { value in
                if moveDelta == nil {
                    focusCanvas()
                    if !isSelected(key) {
                        select(key, extending: extendingSelection)
                    }
                    moving = movingSet()
                }
                moveDelta = snappedDelta(value.translation, grabbing: key)
            }
            .onEnded { value in
                commitMove(snappedDelta(value.translation, grabbing: key))
                moveDelta = nil
                moving = nil
            }
    }

    private func snappedDelta(_ translation: CGSize, grabbing key: BoardObjectKey) -> CGSize {
        let raw = CGSize(width: translation.width / zoom, height: translation.height / zoom)
        guard snapToGrid, let frame = board?.frame(of: key) else {
            return raw
        }
        return CGSize(width: BoardArrange.snap(frame.minX + raw.width) - frame.minX,
                      height: BoardArrange.snap(frame.minY + raw.height) - frame.minY)
    }

    private func movingSet() -> (paths: Set<String>, elements: Set<UUID>) {
        var paths = selection
        var elements = selectedElements
        if let board {
            for box in board.elementList where box.kind == .box && selectedElements.contains(box.id) {
                let carried = board.contents(ofBox: box)
                paths.formUnion(carried.paths)
                elements.formUnion(carried.elements)
            }
        }
        return (paths, elements)
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardCanvas.space))
            .onChanged { value in
                if marquee == nil {
                    focusCanvas()
                    marqueeBase = extendingSelection ? (selection, selectedElements) : ([], [])
                }
                let start = CGPoint(x: value.startLocation.x / zoom, y: value.startLocation.y / zoom)
                let end = CGPoint(x: value.location.x / zoom, y: value.location.y / zoom)
                marquee = (start, end)
                if let rect = marqueeRect {
                    let hit = visibleItems.filter { $0.frame.intersects(rect) }.map(\.path)
                    // Boxes only when wholly enclosed, so a sweep inside one
                    // picks its tiles rather than the box.
                    let hitElements = visibleElements.filter {
                        $0.kind == .box ? rect.contains($0.frame) : $0.frame.intersects(rect)
                    }.map(\.id)
                    selection = marqueeBase.paths.union(hit)
                    selectedElements = marqueeBase.elements.union(hitElements)
                }
            }
            .onEnded { _ in
                marquee = nil
            }
    }

    private var marqueeRect: CGRect? {
        guard let marquee else {
            return nil
        }
        return CGRect(x: min(marquee.start.x, marquee.end.x), y: min(marquee.start.y, marquee.end.y),
                      width: abs(marquee.end.x - marquee.start.x),
                      height: abs(marquee.end.y - marquee.start.y))
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchBase == nil {
                    pinchBase = zoom
                }
                setZoom((pinchBase ?? zoom) * scale, persist: false)
            }
            .onEnded { _ in
                pinchBase = nil
                persistZoom()
            }
    }

    private var extendingSelection: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.command)
    }

    // MARK: - Actions

    /// Take keyboard focus off any text field (the palette's hex field), so
    /// the board's keys — ⌫, Space, Esc, ⌘A — reach the canvas again.
    private func focusCanvas() {
        if let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
    }

    private func tap(_ item: BoardItem) {
        focusCanvas()
        toggleOrSelect(.item(item.path))
    }

    private func tapElement(_ element: BoardElement) {
        guard editingElement != element.id else {
            return
        }
        focusCanvas()
        toggleOrSelect(.element(element.id))
    }

    private func toggleOrSelect(_ key: BoardObjectKey) {
        if extendingSelection && isSelected(key) {
            switch key {
            case .item(let path):
                selection.remove(path)
            case .element(let id):
                selectedElements.remove(id)
            }
        } else {
            select(key, extending: extendingSelection)
        }
    }

    private func isSelected(_ key: BoardObjectKey) -> Bool {
        switch key {
        case .item(let path):
            return selection.contains(path)
        case .element(let id):
            return selectedElements.contains(id)
        }
    }

    private func select(_ key: BoardObjectKey, extending: Bool) {
        if !extending {
            clearSelection()
        }
        switch key {
        case .item(let path):
            selection.insert(path)
        case .element(let id):
            selectedElements.insert(id)
        }
    }

    private func clearSelection() {
        selection = []
        selectedElements = []
    }

    /// Paths an action applies to: the selection when the tile is part of it,
    /// otherwise just the tile.
    private func targets(_ item: BoardItem) -> Set<String> {
        selection.contains(item.path) ? selection : [item.path]
    }

    /// Context-menu Bring to Front (undoable). Moving tiles also lifts them,
    /// inside the same "Move" step.
    private func bringToFront(_ paths: Set<String>) {
        boards.mutate(boardID, undo: undoManager, actionName: "Bring to Front") { board in
            Self.raise(paths, in: &board)
        }
    }

    private static func raise(_ paths: Set<String>, in board: inout MoodBoard) {
        var z = board.maxZ
        for i in board.items.indices.sorted(by: { board.items[$0].z < board.items[$1].z })
        where paths.contains(board.items[i].path) {
            z += 1
            board.items[i].z = z
        }
    }

    private func sendToBack(_ paths: Set<String>) {
        boards.mutate(boardID, undo: undoManager, actionName: "Send to Back") { board in
            let bottom = board.items.map(\.z).min() ?? 0
            var z = bottom - paths.count
            for i in board.items.indices.sorted(by: { board.items[$0].z < board.items[$1].z })
            where paths.contains(board.items[i].path) {
                board.items[i].z = z
                z += 1
            }
        }
    }

    private func commitMove(_ delta: CGSize) {
        guard delta != .zero, let moving else {
            return
        }
        boards.mutate(boardID, undo: undoManager, actionName: "Move") { board in
            for i in board.items.indices where moving.paths.contains(board.items[i].path) {
                board.items[i].frame = Self.clamped(board.items[i].frame.offsetBy(dx: delta.width,
                                                                                   dy: delta.height))
            }
            for id in moving.elements {
                board.updateElement(id) { element in
                    element.frame = Self.clamped(element.frame.offsetBy(dx: delta.width, dy: delta.height))
                }
            }
            Self.raise(moving.paths, in: &board)
        }
    }

    private static func clamped(_ frame: CGRect) -> CGRect {
        CGRect(x: max(0, frame.minX), y: max(0, frame.minY), width: frame.width, height: frame.height)
    }

    /// Corner-handle drag: keeps the tile's shape unless ⇧ is held.
    private func resize(_ item: BoardItem, by translation: CGSize, ended: Bool) {
        let start = item.frame.size
        let minSide: CGFloat = 40
        let width = max(minSide, start.width + translation.width / zoom)
        let height: CGFloat
        if NSEvent.modifierFlags.contains(.shift) {
            height = max(minSide, start.height + translation.height / zoom)
        } else {
            height = max(minSide, width * start.height / max(start.width, 1))
        }
        var size = CGSize(width: width.rounded(), height: height.rounded())
        if snapToGrid {
            let snappedWidth = max(BoardArrange.gridStep, BoardArrange.snap(size.width))
            size = CGSize(width: snappedWidth, height: (snappedWidth * size.height / size.width).rounded())
        }
        guard ended else {
            resizing = (item.path, size)
            return
        }
        resizing = nil
        boards.mutate(boardID, undo: undoManager, actionName: "Resize") { board in
            if let i = board.items.firstIndex(where: { $0.path == item.path }) {
                board.items[i].frame.size = size
            }
        }
    }

    private func removeSelected() {
        let elements = selectedElements
        guard !elements.isEmpty else {
            remove(selection)
            return
        }
        let paths = selection
        boards.mutate(boardID, undo: undoManager, actionName: "Delete") { board in
            board.items.removeAll { paths.contains($0.path) }
            board.dismissed.formUnion(paths)
            board.elements?.removeAll { elements.contains($0.id) }
        }
        clearSelection()
    }

    private func remove(_ paths: Set<String>) {
        guard !paths.isEmpty else {
            return
        }
        boards.mutate(boardID, undo: undoManager, actionName: "Remove from Board") { board in
            board.items.removeAll { paths.contains($0.path) }
            board.dismissed.formUnion(paths)
        }
        selection.subtract(paths)
    }

    // MARK: - Notes, labels, boxes

    /// The middle of what's on screen, in canvas units.
    private var visibleCenter: CGPoint {
        CGPoint(x: (-scrollOrigin.x + viewport.width / 2) / zoom,
                y: (-scrollOrigin.y + viewport.height / 2) / zoom)
    }

    private func addElement(_ kind: BoardElement.Kind) {
        guard let board else {
            return
        }
        let element = BoardElement.make(kind, at: visibleCenter, z: board.maxElementZ + 1)
        let names: [BoardElement.Kind: String] = [.note: "Add Note", .label: "Add Label", .box: "Add Box"]
        boards.mutate(boardID, undo: undoManager, actionName: names[kind]) { board in
            board.elements = board.elementList + [element]
        }
        clearSelection()
        selectedElements = [element.id]
        editingElement = element.id
    }

    /// ⌘G: a titled box around the selection, under everything in it.
    private func boxAroundSelection() {
        guard let board else {
            return
        }
        let frames = selectedKeys.compactMap { board.frame(of: $0) }
        guard let bounds = frames.reduce(nil as CGRect?, { ($0 ?? $1).union($1) }) else {
            return
        }
        var box = BoardElement.make(.box, at: .zero, z: 0)
        box.text = "Group"
        let pad: CGFloat = 24
        box.frame = Self.clamped(CGRect(x: bounds.minX - pad,
                                        y: bounds.minY - pad - box.boxHeaderHeight,
                                        width: bounds.width + pad * 2,
                                        height: bounds.height + pad * 2 + box.boxHeaderHeight))
        box.z = (board.elementList.filter { $0.kind == .box }.map(\.z).min() ?? 1) - 1
        boards.mutate(boardID, undo: undoManager, actionName: "Box Around Selection") { board in
            board.elements = board.elementList + [box]
        }
        clearSelection()
        selectedElements = [box.id]
    }

    private func beginEditing(_ element: BoardElement) {
        clearSelection()
        selectedElements = [element.id]
        editingElement = element.id
    }

    private func commitText(_ id: UUID, _ text: String) {
        if editingElement == id {
            editingElement = nil
        }
        guard board?.elementList.first(where: { $0.id == id })?.text != text else {
            return
        }
        boards.mutate(boardID, undo: undoManager, actionName: "Edit Text") { board in
            board.updateElement(id) { $0.text = text }
        }
    }

    private func resizeElement(_ element: BoardElement, by translation: CGSize, ended: Bool) {
        let minSize: CGSize = element.kind == .label ? CGSize(width: 40, height: 24) : CGSize(width: 80, height: 50)
        var size = CGSize(width: max(minSize.width, element.frame.width + translation.width / zoom),
                          height: max(minSize.height, element.frame.height + translation.height / zoom))
        if snapToGrid {
            size = CGSize(width: max(BoardArrange.gridStep, BoardArrange.snap(size.width)),
                          height: max(BoardArrange.gridStep, BoardArrange.snap(size.height)))
        }
        guard ended else {
            resizingElement = (element.id, size)
            return
        }
        resizingElement = nil
        boards.mutate(boardID, undo: undoManager, actionName: "Resize") { board in
            board.updateElement(element.id) { $0.frame.size = size }
        }
    }

    private func setElements(_ ids: Set<UUID>, actionName: String, _ change: @escaping (inout BoardElement) -> Void) {
        boards.mutate(boardID, undo: undoManager, actionName: actionName) { board in
            for id in ids {
                board.updateElement(id, change)
            }
        }
    }

    private func elementTargets(_ element: BoardElement) -> Set<UUID> {
        selectedElements.contains(element.id) ? selectedElements : [element.id]
    }

    @ViewBuilder
    private func elementMenu(_ element: BoardElement) -> some View {
        let ids = elementTargets(element)
        Button(element.kind == .box ? "Rename" : "Edit Text") { beginEditing(element) }
        if element.kind == .box, let board {
            Button("Select Contents") {
                let contents = board.contents(ofBox: element)
                selection = contents.paths
                selectedElements = contents.elements
            }
        }
        Menu(element.kind == .label ? "Text Color" : "Color") {
            Button("Default") { setElements(ids, actionName: "Color") { $0.colorHex = nil } }
            Divider()
            ForEach(BoardColors.presets, id: \.hex) { preset in
                Button(preset.name) { setElements(ids, actionName: "Color") { $0.colorHex = preset.hex } }
            }
            let palette = board?.palette ?? []
            if !palette.isEmpty {
                Divider()
                ForEach(palette) { swatch in
                    Button("Palette \(swatch.hex)") {
                        setElements(ids, actionName: "Color") { $0.colorHex = swatch.hex }
                    }
                }
            }
        }
        Menu("Text Size") {
            ForEach(element.fontSizeChoices, id: \.size) { choice in
                Button(choice.name) { setElements(ids, actionName: "Text Size") { $0.fontSize = choice.size } }
            }
        }
        Divider()
        Button("Bring Forward") {
            let top = board?.maxElementZ ?? 0
            setElements(ids, actionName: "Bring Forward") { $0.z = top + 1 }
        }
        Button("Send Backward") {
            let bottom = board?.elementList.map(\.z).min() ?? 0
            setElements(ids, actionName: "Send Backward") { $0.z = bottom - 1 }
        }
        Divider()
        Button("Delete", role: .destructive) {
            boards.mutate(boardID, undo: undoManager, actionName: "Delete") { board in
                board.elements?.removeAll { ids.contains($0.id) }
            }
            selectedElements.subtract(ids)
        }
    }

    // MARK: - Arrange

    private func arrange(_ action: BoardArrange.Action, name: String) {
        guard let board else {
            return
        }
        var frames: [BoardObjectKey: CGRect] = [:]
        for key in selectedKeys {
            frames[key] = board.frame(of: key)
        }
        let arranged = BoardArrange.apply(action, to: frames)
        boards.mutate(boardID, undo: undoManager, actionName: name) { board in
            for (key, frame) in arranged {
                board.setFrame(Self.clamped(frame), for: key)
            }
        }
    }

    @ViewBuilder
    private var arrangeMenuContent: some View {
        let count = selectedKeys.count
        Group {
            Button("Align Left Edges") { arrange(.alignLeft, name: "Align") }
            Button("Align Centers") { arrange(.alignCenterX, name: "Align") }
            Button("Align Right Edges") { arrange(.alignRight, name: "Align") }
            Divider()
            Button("Align Top Edges") { arrange(.alignTop, name: "Align") }
            Button("Align Middles") { arrange(.alignCenterY, name: "Align") }
            Button("Align Bottom Edges") { arrange(.alignBottom, name: "Align") }
        }
        .disabled(count < 2)
        Divider()
        Button("Distribute Horizontally") { arrange(.distributeHorizontally, name: "Distribute") }
            .disabled(count < 3)
        Button("Distribute Vertically") { arrange(.distributeVertically, name: "Distribute") }
            .disabled(count < 3)
        Divider()
        Button("Match Widths") { arrange(.matchWidth, name: "Match Size") }
            .disabled(count < 2)
        Button("Match Heights") { arrange(.matchHeight, name: "Match Size") }
            .disabled(count < 2)
        Button("Arrange in Grid") { arrange(.grid, name: "Arrange in Grid") }
            .disabled(count < 2)
        Divider()
        Button("Box Around Selection") { boxAroundSelection() }
            .disabled(count == 0)
        Toggle("Snap to Grid", isOn: $snapToGrid)
    }

    private func urls(_ paths: Set<String>) -> [URL] {
        visibleItems
            .filter { paths.contains($0.path) }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { VaultDisk.resolvedURL(forLogicalPath: $0.path) }
    }

    private func quickLook(_ item: BoardItem) {
        let list = urls(targets(item))
        if !list.isEmpty {
            QuickLookOpener.open(list)
        }
    }

    private func quickLookSelection() {
        let list = urls(selection.isEmpty ? Set(visibleItems.map(\.path)) : selection)
        if !list.isEmpty {
            QuickLookOpener.open(list)
        }
    }

    @ViewBuilder
    private func tileMenu(_ item: BoardItem) -> some View {
        let paths = targets(item)
        Button("Quick Look") { QuickLookOpener.open(urls(paths)) }
        Button("Open") { urls(paths).forEach { NSWorkspace.shared.open($0) } }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls(paths)) }
        Divider()
        Button("Bring to Front") { bringToFront(paths) }
        Button("Send to Back") { sendToBack(paths) }
        Divider()
        Button(paths.count == 1 ? "Remove from Board" : "Remove \(paths.count) from Board",
               role: .destructive) { remove(paths) }
    }

    private func dropFiles(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            return false
        }
        let point = CGPoint(x: max(0, location.x / zoom), y: max(0, location.y / zoom))
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadFileURL(provider) {
                    urls.append(url)
                }
            }
            // Previews dragged in from a connected service are saved first.
            let paths = await store.libraryURLs(for: urls).map { VaultDisk.originalPath(of: $0.path) }
            await boards.addFiles(paths, to: boardID, at: point, undo: undoManager)
        }
        return true
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data = data as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: data as? URL)
                }
            }
        }
    }

    private func refreshLockedFilter() {
        guard !store.revealed, let board else {
            hiddenWhileLocked = []
            return
        }
        hiddenWhileLocked = store.privatePaths(among: board.items.map(\.path))
    }

    // MARK: - Source link (a collection on a connected service)

    private var sourceLink: SourceLink? { sources.link(forBoard: boardID) }

    private var boardIsPrivate: Bool {
        board?.source.map { store.isPrivateQuery($0) } ?? false
    }

    private func sourceName(_ link: SourceLink) -> String {
        sources.plugin(link.pluginID)?.manifest.source?.displayName ?? "source"
    }

    /// Pull new remote items; `foldInSource` runs when the pull finishes.
    private func syncSource(_ link: SourceLink) {
        syncingSource = true
        sources.sync(link)
    }

    /// Put the collection's files on the board (minus ones removed from it),
    /// then offer to send board files the collection doesn't have yet.
    private func foldInSource(_ link: SourceLink, offerSend: Bool) {
        Task { @MainActor in
            let dismissed = board?.dismissed ?? []
            let members = sources.memberPaths(of: link).filter { !dismissed.contains($0) }
            await boards.addFiles(members, to: boardID, undo: undoManager)
            guard offerSend, !boardIsPrivate,
                  sources.plugin(link.pluginID)?.manifest.source?.canPush == true else {
                return
            }
            let unsent = sources.unsentPaths(visibleItems.map(\.path), link: link)
                .map { URL(fileURLWithPath: $0) }
            sendCandidates = sources.shareable(unsent).allowed
            confirmingSend = !sendCandidates.isEmpty
        }
    }

    private var sendPrompt: String {
        guard let link = sourceLink else {
            return ""
        }
        let count = sendCandidates.count
        return "Send \(count) board file\(count == 1 ? "" : "s") to “\(link.collection.title)”?"
    }

    private var sendWarning: String {
        guard let link = sourceLink else {
            return ""
        }
        var text = "These are on the board but not in the \(sourceName(link)) \(sources.plugin(link.pluginID)?.manifest.source?.noun ?? "collection") yet."
        if let info = sources.plugin(link.pluginID)?.manifest.source, info.isShared(link.collection.visibility) {
            text += " It is \(info.visibilityLabel(link.collection.visibility)?.lowercased() ?? "shared"): others can see what you send."
        }
        return text + " Hidden files are never sent; your tags stay on this Mac."
    }

    private func sendCandidatesToSource() {
        guard let link = sourceLink, let plugin = sources.plugin(link.pluginID) else {
            return
        }
        sources.push(sendCandidates, to: link.collection, plugin: plugin)
        sendCandidates = []
    }

    @ViewBuilder
    private var sourceMenuItems: some View {
        if let link = sourceLink {
            Button("Sync with “\(link.collection.title)”") { syncSource(link) }
                .disabled(sources.busy)
            if let page = link.collection.url, let url = URL(string: page) {
                Button("Open “\(link.collection.title)” on \(sourceName(link))") { NSWorkspace.shared.open(url) }
            }
            if sources.plugin(link.pluginID)?.manifest.source?.canEditCollection == true,
               link.collection.writable != false {
                Button("Edit \(sourceName(link)) \(sources.plugin(link.pluginID)?.manifest.source?.noun.capitalized ?? "Collection")…") {
                    openWindow(id: "sources")
                    sources.route = .editCollection(linkID: link.id)
                }
            }
            Button("Unlink from \(sourceName(link))") { sources.setBoard(nil, for: link) }
        } else {
            ForEach(sources.plugins) { plugin in
                let info = plugin.manifest.source
                Button("Link to \(info?.displayName ?? plugin.manifest.name) \(info?.noun.capitalized ?? "Collection")…") {
                    openWindow(id: "sources")
                    sources.route = .linkBoard(pluginID: plugin.id, boardID: boardID,
                                               boardName: board?.name ?? "Board")
                }
                .disabled(boardIsPrivate)
            }
        }
        if sourceLink == nil {
            ForEach(sources.plugins.filter {
                $0.manifest.source?.canPush == true && $0.manifest.source?.canCreateCollection == true
            }) { plugin in
                Button("Publish Board to \(plugin.manifest.source?.displayName ?? plugin.manifest.name)…") {
                    let urls = visibleItems.map { URL(fileURLWithPath: $0.path) }
                    openWindow(id: "sources")
                    sources.route = .publishBoard(pluginID: plugin.id, boardID: boardID,
                                                  boardName: board?.name ?? "Board", urls: urls)
                }
                .disabled(boardIsPrivate || visibleItems.isEmpty)
            }
        }
        ForEach(sources.plugins.filter { $0.manifest.source?.canPush == true }) { plugin in
            Button("Send Board to \(plugin.manifest.source?.displayName ?? plugin.manifest.name)…") {
                let urls = visibleItems.map { URL(fileURLWithPath: $0.path) }
                openWindow(id: "sources")
                sources.route = .send(pluginID: plugin.id, urls: urls, label: "“\(board?.name ?? "Board")”")
            }
            .disabled(boardIsPrivate || visibleItems.isEmpty)
        }
        if boardIsPrivate && !sources.plugins.isEmpty {
            Text("Private boards stay on this Mac")
        }
    }

    // MARK: - Query link

    private func refreshFromQuery() {
        guard let source = board?.source, !refreshing else {
            return
        }
        refreshing = true
        Task { @MainActor in
            store.applyQuery(source)
            await store.waitForSearch()
            let dismissed = board?.dismissed ?? []
            let paths = store.results
                .filter { $0.kind != .folder }
                .map { VaultDisk.originalPath(of: $0.id) }
                .filter { !dismissed.contains($0) }
            await boards.addFiles(paths, to: boardID, undo: undoManager)
            refreshing = false
        }
    }

    private func showQuery() {
        guard let source = board?.source else {
            return
        }
        store.applyQuery(source)
        MainWindowRef.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Zoom

    private func setZoom(_ value: CGFloat, persist: Bool = true) {
        zoom = min(max(value, BoardCanvas.zoomRange.lowerBound), BoardCanvas.zoomRange.upperBound)
        if persist {
            persistZoom()
        }
    }

    private func persistZoom() {
        boards.mutate(boardID) { $0.zoom = Double(zoom) }
    }

    private func fit(_ proxy: ScrollViewProxy) {
        guard let bounds = allFrames.reduce(nil as CGRect?, { ($0 ?? $1).union($1) }),
              viewport.width > 0, viewport.height > 0 else {
            return
        }
        let margin = BoardLayout.margin
        setZoom(min(viewport.width / (bounds.maxX + margin), viewport.height / (bounds.maxY + margin)))
        proxy.scrollTo("origin", anchor: .topLeading)
    }

    // MARK: - Toolbar & keys

    @ToolbarContentBuilder
    private func toolbar(_ proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if board?.source != nil {
                Button { refreshFromQuery() } label: {
                    Label("Refresh from Query", systemImage: "arrow.clockwise")
                }
                .help("Add new matches for the board's query (removed files stay off)")
                .disabled(refreshing)
                Button { showQuery() } label: {
                    Label("Show Query", systemImage: "magnifyingglass")
                }
                .help("Show the board's query in the main window")
            }
            if let link = sourceLink {
                Button { syncSource(link) } label: {
                    Label("Sync with \(sourceName(link))", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Add new items from “\(link.collection.title)”, then offer to send board files it doesn't have")
                .disabled(sources.busy)
            }
            Button { setZoom(zoom / 1.25) } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom out (⌘−)")
            Text("\(Int((zoom * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)
            Button { setZoom(zoom * 1.25) } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help("Zoom in (⌘=)")
            Button { fit(proxy) } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit the whole board (⌘0)")
            Menu {
                Button("Note  (N)") { addElement(.note) }
                Button("Label  (T)") { addElement(.label) }
                Button("Box  (B)") { addElement(.box) }
            } label: {
                Label("Add", systemImage: "note.text.badge.plus")
            }
            .help("Add a note, label or box")
            Menu {
                arrangeMenuContent
            } label: {
                Label("Arrange", systemImage: "align.horizontal.left")
            }
            .help("Align, distribute and size the selection · snap to grid")
            Button { showsPalette.toggle() } label: {
                Label("Palette", systemImage: "paintpalette")
            }
            .help(showsPalette ? "Hide the color palette" : "Show the color palette")
            Menu {
                Button("Export as Image…") { exportImage() }
                Button("Export as Folder…") { exportFolder() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(visibleItems.isEmpty || exportStatus != nil)
            .help("Export the board")
            Menu {
                Button("Rename…") {
                    renameText = board?.name ?? ""
                    renaming = true
                }
                Button("Tidy Up") {
                    boards.mutate(boardID, undo: undoManager, actionName: "Tidy Up") { board in
                        board.items = BoardLayout.tidy(board.items)
                    }
                }
                .disabled(visibleItems.isEmpty)
                if !sources.plugins.isEmpty {
                    Divider()
                    sourceMenuItems
                }
                Divider()
                Button("Delete Board…", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("Board", systemImage: "ellipsis.circle")
            }
        }
    }

    /// The board's bare-key shortcuts. Handled by an event monitor rather
    /// than `keyboardShortcut`, so they never steal keys from a text field.
    private var keyHandler: some View {
        BoardKeyHandler(onWindow: { boards.register(window: $0, for: boardID) }) { key in
            switch key {
            case .undo:
                if undoManager.canUndo {
                    undoManager.undo()
                }
            case .redo:
                if undoManager.canRedo {
                    undoManager.redo()
                }
            case .delete:
                removeSelected()
            case .space:
                quickLookSelection()
            case .escape:
                clearSelection()
            case .selectAll:
                selection = Set(visibleItems.map(\.path))
                selectedElements = Set(visibleElements.map(\.id))
            case .newNote:
                addElement(.note)
            case .newLabel:
                addElement(.label)
            case .newBox:
                addElement(.box)
            case .boxAroundSelection:
                boxAroundSelection()
            }
        }
    }

    // MARK: - Export

    private func exportImage() {
        let items = visibleItems
        let elements = visibleElements
        guard let bounds = allFrames.reduce(nil as CGRect?, { ($0 ?? $1).union($1) }) else {
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Board as Image"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = QueryExporter.folderName(for: board?.name ?? "Board") + ".png"
        guard panel.runModal() == .OK, let dest = panel.url else {
            return
        }
        exportStatus = "Rendering image…"
        Task { @MainActor in
            defer { exportStatus = nil }
            var images: [String: NSImage] = [:]
            for item in items {
                let url = VaultDisk.resolvedURL(forLogicalPath: item.path)
                let side = min(1024, max(item.frame.width, item.frame.height) * 2)
                images[item.path] = await ThumbnailCache.shared.thumbnail(for: url, size: side)
            }
            let pad = BoardLayout.margin
            let snapshot = BoardSnapshot(items: items.sorted { $0.z < $1.z },
                                         elements: elements.sorted { $0.z < $1.z }, images: images,
                                         origin: CGPoint(x: bounds.minX - pad, y: bounds.minY - pad),
                                         size: CGSize(width: bounds.width + pad * 2,
                                                      height: bounds.height + pad * 2))
            let renderer = ImageRenderer(content: snapshot)
            let longest = max(snapshot.size.width, snapshot.size.height)
            renderer.scale = min(2, 16_000 / max(longest, 1))
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                return
            }
            try? png.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    private func exportFolder() {
        let paths = visibleItems.map(\.path)
        guard !paths.isEmpty, let board else {
            return
        }
        guard let choice = QueryExporter.askDestination(
            suggestedName: QueryExporter.folderName(for: board.name), count: paths.count) else {
            return
        }
        let manifest = board.source.map { q in
            QueryExportManifest(created: Date(), scope: store.scopeURL.path, query: board.name,
                                groups: q.groups.filter { !$0.sets.isEmpty }, excludes: q.excludes,
                                kinds: q.kinds ?? [], exts: q.exts ?? [], searchQuery: q.searchQuery,
                                mode: choice.mode.rawValue, count: paths.count)
        }
        exportStatus = "Exporting…"
        Task.detached(priority: .userInitiated) {
            let urls = paths.map { VaultDisk.resolvedURL(forLogicalPath: $0) }
            let outcome = QueryExporter.materialize(urls, into: choice.folder, mode: choice.mode,
                                                    manifest: manifest)
            await MainActor.run {
                exportStatus = nil
                QueryExporter.finish(outcome, folder: choice.folder, mode: choice.mode)
            }
        }
    }
}

/// Keys the board canvas answers to.
enum BoardKey {
    case delete, space, escape, selectAll, undo, redo
    case newNote, newLabel, newBox, boxAroundSelection
}

/// Watches key-downs aimed at its own window and reports board keys, except
/// while a text field is being edited (the field editor is an NSText).
struct BoardKeyHandler: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void = { _ in }
    let onKey: (BoardKey) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            context.coordinator.handle(event) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onKey: onKey)
    }

    final class Coordinator {
        var onKey: (BoardKey) -> Void
        weak var view: NSView?
        var monitor: Any?

        init(onKey: @escaping (BoardKey) -> Void) {
            self.onKey = onKey
        }

        func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window else {
                return false
            }
            if window.firstResponder is NSText {
                // Esc finishes editing a note, label or field; other keys type.
                if event.keyCode == 53 {
                    window.makeFirstResponder(nil)
                    return true
                }
                return false
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let character = event.charactersIgnoringModifiers?.lowercased()
            let key: BoardKey?
            if flags == .command && character == "a" {
                key = .selectAll
            } else if flags == .command && character == "g" {
                key = .boxAroundSelection
            } else if flags.isEmpty && character == "n" {
                key = .newNote
            } else if flags.isEmpty && character == "t" {
                key = .newLabel
            } else if flags.isEmpty && character == "b" {
                key = .newBox
            } else if character == "z" && (flags == .command || flags == .control) {
                key = .undo
            } else if character == "z" && (flags == [.command, .shift] || flags == [.control, .shift]) {
                key = .redo
            } else if !flags.isDisjoint(with: [.command, .control, .option]) {
                key = nil
            } else {
                switch event.keyCode {
                case 51, 117:
                    key = .delete
                case 49:
                    key = .space
                case 53:
                    key = .escape
                default:
                    key = nil
                }
            }
            guard let key else {
                return false
            }
            onKey(key)
            return true
        }
    }
}

/// Static rendering of a board for image export.
private struct BoardSnapshot: View {
    let items: [BoardItem]
    let elements: [BoardElement]
    let images: [String: NSImage]
    let origin: CGPoint
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(elements.filter { $0.kind == .box }) { element in
                elementView(element)
            }
            ForEach(items) { item in
                Group {
                    if let image = images[item.path] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: item.frame.width, height: item.frame.height)
                .offset(x: item.frame.minX - origin.x, y: item.frame.minY - origin.y)
            }
            ForEach(elements.filter { $0.kind != .box }) { element in
                elementView(element)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }

    private func elementView(_ element: BoardElement) -> some View {
        BoardElementView(element: element, size: element.frame.size, zoom: 1,
                         selected: false, editing: false,
                         onCommit: { _ in }, onResize: { _, _ in })
            .offset(x: element.frame.minX - origin.x, y: element.frame.minY - origin.y)
    }
}

private struct ScrollOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// The main Overlap window, so a board can bring it forward ("Show Query").
enum MainWindowRef {
    static weak var window: NSWindow?
}

/// Records the hosting window into `MainWindowRef`.
struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            MainWindowRef.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
