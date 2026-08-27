import SwiftUI
import AppKit
import Quartz

struct ResultsGridView: View {
    @EnvironmentObject var store: TagStore
    @State private var thumbSize: CGFloat = 150
    @State private var showNewTag = false
    @State private var newTagName = ""
    @State private var pendingURLs: [URL] = []
    @State private var keyMonitor: Any?
    @State private var tagInput = ""
    @State private var didSuggest = false
    @FocusState private var tagFieldFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize + 12), spacing: 10)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.mode == .queue { queueBar } else { QueryBar(thumbSize: $thumbSize) }
            Divider()
            if store.results.isEmpty {
                emptyState
            } else if store.showPreview {
                HSplitView {
                    grid.frame(minWidth: 220)
                    PreviewPane(item: primarySelected).frame(minWidth: 260)
                }
            } else {
                grid
            }
            tagFooter
            quickTagBar
        }
        .sheet(isPresented: $showNewTag) { newTagSheet }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: store.tagFocusRequest) { _ in
            if !store.selection.isEmpty { tagFieldFocused = true }
        }
    }

    // MARK: Quick-tag bar

    private var trimmedInput: String { tagInput.trimmingCharacters(in: .whitespaces) }

    private var suggestions: [String] {
        let q = trimmedInput.lowercased()
        guard !q.isEmpty else { return [] }
        let matched = store.tagCounts.keys
            .filter { $0.lowercased().contains(q) }
            .sorted { (store.tagCounts[$0] ?? 0) > (store.tagCounts[$1] ?? 0) }
        return Array(matched.prefix(8))
    }

    private var canCreate: Bool {
        !trimmedInput.isEmpty && !store.tagCounts.keys.contains(trimmedInput)
    }

    private var quickTagBar: some View {
        VStack(spacing: 0) {
            if didSuggest {
                Divider()
                suggestedRow
            }
            if tagFieldFocused && (!suggestions.isEmpty || canCreate) {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { tag in
                        suggestionRow(label: tag, count: store.tagCounts[tag], system: "tag") {
                            applyTag(tag)
                        }
                    }
                    if canCreate {
                        suggestionRow(label: "Create “\(trimmedInput)”", count: nil,
                                      system: "plus.circle") {
                            applyTag(trimmedInput)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                TextField(tagFieldPlaceholder, text: $tagInput)
                    .textFieldStyle(.plain)
                    .focused($tagFieldFocused)
                    .onSubmit { submitTag() }
                    .onExitCommand { tagInput = ""; tagFieldFocused = false }
                if !store.selection.isEmpty {
                    Text("\(store.selection.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { runSuggest() } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.suggesting)
                    .help("Suggest tags for the selection")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .tutorialAnchor(.tagBar)
        .onChange(of: store.selection) { _ in
            didSuggest = false
            store.clearSuggestions()
        }
    }

    /// The plugin-suggested tag chips (shown after the user hits Suggest).
    private var suggestedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                Text("Suggested").font(.caption).foregroundStyle(.secondary)
                if store.suggesting {
                    ProgressView().controlSize(.small)
                } else if store.suggestions.isEmpty {
                    Text("none").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(store.suggestions) { s in
                    Button { applyTag(s.tag) } label: {
                        HStack(spacing: 4) {
                            Text(s.tag).font(.caption)
                            Text("\(Int(s.confidence * 100))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .help("\(s.source) · \(Int(s.confidence * 100))%")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private func runSuggest() {
        let items = store.results.filter { store.selection.contains($0.id) }
        guard !items.isEmpty else { return }
        didSuggest = true
        store.suggestTags(for: items)
    }

    private var tagFieldPlaceholder: String {
        store.selection.isEmpty
            ? "Select files, press T to tag"
            : "Add tag to \(store.selection.count) selected — ⏎ applies, Esc closes"
    }

    private func suggestionRow(label: String, count: Int?, system: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).foregroundStyle(.secondary).font(.caption)
                Text(label)
                Spacer()
                if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submitTag() {
        let t = trimmedInput
        guard !t.isEmpty else { tagFieldFocused = false; return }
        applyTag(suggestions.first ?? t)
    }

    private func applyTag(_ tag: String) {
        let urls = store.selectedURLs()
        guard !urls.isEmpty else { return }
        store.addTag(tag, to: urls)
        tagInput = ""
        tagFieldFocused = true   // stay ready for the next tag
    }

    /// Space bar opens Quick Look — but only when the user isn't typing in a
    /// text field and Quick Look isn't already up (so its own arrow-key paging
    /// keeps working).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleKey(event) }
        }
    }

    /// Returns nil to swallow the event, or the event to let it pass through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSText || responder is NSTextView { return event }

        // ⌘Z undo, ⌘⇧Z redo.
        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) { store.performRedo() }
            else { store.performUndo() }
            return nil
        }

        // Quick Look up: it pages with ←/→ itself; we add ↑/↓ = jump one row.
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            let count = store.results.count
            guard count > 0 else { return event }
            let step = max(1, store.columnsHint)
            switch event.keyCode {
            case 125: // down
                panel.currentPreviewItemIndex =
                    min(panel.currentPreviewItemIndex + step, count - 1)
                return nil
            case 126: // up
                panel.currentPreviewItemIndex =
                    max(panel.currentPreviewItemIndex - step, 0)
                return nil
            default:
                return event
            }
        }

        // ⌘⌫ moves the selection to the Trash.
        if event.keyCode == 51, event.modifierFlags.contains(.command) {
            store.trash(store.selectedURLs())
            return nil
        }

        switch event.keyCode {
        case 17: store.requestTagFocus(); return nil // T — focus quick-tag bar
        case 49: quickLook(); return nil            // space
        case 123: store.moveSelection(dx: -1, dy: 0); return nil  // left
        case 124: store.moveSelection(dx: 1, dy: 0); return nil   // right
        case 125: store.moveSelection(dx: 0, dy: 1); return nil   // down
        case 126: store.moveSelection(dx: 0, dy: -1); return nil  // up
        default: return event
        }
    }

    private var primarySelected: FileItem? {
        store.results.first { store.selection.contains($0.id) }
    }

    @ViewBuilder private var tagFooter: some View {
        if let item = primarySelected {
            Divider()
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if item.tags.isEmpty {
                    Text("no tags").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(item.tags, id: \.self) { tag in
                            Button {
                                store.removeTag(tag, from: [item.url])
                            } label: {
                                HStack(spacing: 3) {
                                    Text(tag).font(.caption)
                                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Remove “\(tag)”")
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxHeight: 32)
        }
    }

    /// Open Quick Look over ALL current results so the arrow keys page through
    /// them, starting at `item` (or the current selection). As the user pages in
    /// Quick Look, the grid selection follows.
    private func quickLook(_ item: FileItem? = nil) {
        let all = store.results
        guard !all.isEmpty else { return }
        let ids = all.map(\.id)
        let startID = item?.id ?? primarySelected?.id
        let idx = all.firstIndex { $0.id == startID } ?? 0
        QuickLookOpener.open(all.map(\.url), startAt: idx) { i in
            guard ids.indices.contains(i) else { return }
            store.selection = [ids[i]]
            store.scrollTarget = ids[i]
        }
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.results) { item in
                            ThumbnailCell(item: item, size: thumbSize,
                                          selected: store.selection.contains(item.id))
                                .id(item.id)
                                .onTapGesture(count: 2) { handleOpen(item) }
                                .onTapGesture { handleClick(item) }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.scrollTarget) { target in
                    if let target {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
            .onAppear { store.columnsHint = computeColumns(geo.size.width) }
            .onChange(of: geo.size.width) { store.columnsHint = computeColumns($0) }
            .onChange(of: thumbSize) { _ in store.columnsHint = computeColumns(geo.size.width) }
        }
        .tutorialAnchor(.grid)
    }

    private func computeColumns(_ width: CGFloat) -> Int {
        max(1, Int((width - 14) / (thumbSize + 22)))
    }

    private var queueBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
            if store.queueDrill.isEmpty {
                Text("Queue").font(.headline)
            } else {
                queueBreadcrumb
            }
            Text("\(store.results.count) untagged").foregroundStyle(.secondary)
            TypeFilterMenu(queue: true)
            TypeFilterChips()
            Spacer()
            SortMenu()
            Slider(value: $thumbSize, in: 90...280).frame(width: 120)
            Button { store.applyQueue() } label: {
                Label("Apply \(store.taggedQueueCount)", systemImage: "arrow.right.circle")
            }
            .disabled(store.taggedQueueCount == 0)
            .help("Move tagged items into the library")
        }
        .padding(8)
    }

    /// Home + drilled folder names; click any crumb to pop back to it.
    private var queueBreadcrumb: some View {
        HStack(spacing: 4) {
            Button { store.popQueueDrill(to: 0) } label: {
                Image(systemName: "house.fill")
            }
            .buttonStyle(.plain).help("Back to watched folders")
            ForEach(Array(store.queueDrill.enumerated()), id: \.offset) { i, url in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(url.lastPathComponent) { store.popQueueDrill(to: i + 1) }
                    .buttonStyle(.plain)
                    .fontWeight(i == store.queueDrill.count - 1 ? .semibold : .regular)
            }
        }
        .font(.headline)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.mode == .queue {
                Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Queue empty")
                    .foregroundStyle(.secondary)
                Text("Add a watched folder, or all found files are already tagged")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "tag").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Click tags in the sidebar to filter")
                    .foregroundStyle(.secondary)
                Text("Click cycles: include → exclude → off")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Interaction

    private func handleClick(_ item: FileItem) {
        // Drop focus from the sidebar search field so Space/arrows target the grid.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let flags = NSEvent.modifierFlags
        let items = store.results
        guard let clicked = items.firstIndex(where: { $0.id == item.id }) else { return }

        if flags.contains(.shift),
           let anchorID = store.selectionAnchor,
           let anchor = items.firstIndex(where: { $0.id == anchorID }) {
            let range = anchor <= clicked ? anchor...clicked : clicked...anchor
            store.selection = Set(items[range].map(\.id))
            // keep the anchor so further shift-clicks re-range from it
        } else if flags.contains(.command) {
            if store.selection.contains(item.id) { store.selection.remove(item.id) }
            else { store.selection.insert(item.id) }
            store.selectionAnchor = item.id
        } else {
            store.selection = [item.id]
            store.selectionAnchor = item.id
        }
    }

    /// Double-click: in the queue, step into a folder; otherwise Quick Look.
    private func handleOpen(_ item: FileItem) {
        if store.mode == .queue && item.kind == .folder {
            store.enterQueueFolder(item.url)
        } else {
            QuickLookOpener.open(targetURLs(for: item))
        }
    }

    private func exportURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let fm = FileManager.default
        for url in urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try? fm.copyItem(at: url, to: dest)
        }
    }

    private func targetURLs(for item: FileItem) -> [URL] {
        if store.selection.contains(item.id) {
            let urls = store.selectedURLs()
            return urls.isEmpty ? [item.url] : urls
        }
        return [item.url]
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        Button("Quick Look") {
            store.selection = store.selection.contains(item.id) ? store.selection : [item.id]
            QuickLookOpener.open(targetURLs(for: item))
        }
        Button("Open") { NSWorkspace.shared.open(item.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targetURLs(for: item))
        }
        Button("Copy Path") {
            let paths = targetURLs(for: item).map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
        }
        Button("Export…") { exportURLs(targetURLs(for: item)) }
        if item.kind == .image {
            Button("Fix Extension") { store.fixExtension(targetURLs(for: item)) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            store.trash(targetURLs(for: item))
        }
        Divider()
        Menu("Add Tag") {
            ForEach(store.tagCounts.keys.sorted(), id: \.self) { tag in
                Button(tag) { store.addTag(tag, to: targetURLs(for: item)) }
            }
            Divider()
            Button("New Tag…") {
                pendingURLs = targetURLs(for: item)
                newTagName = ""
                showNewTag = true
            }
        }
        if !item.tags.isEmpty {
            Menu("Remove Tag") {
                ForEach(item.tags, id: \.self) { tag in
                    Button(tag) { store.removeTag(tag, from: targetURLs(for: item)) }
                }
            }
        }
    }

    private var newTagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tag").font(.headline)
            Text("Use “cat/Name” or “type/Name” for subtags.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("cat/Fashion", text: $newTagName)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { showNewTag = false }
                Button("Add") {
                    let t = newTagName.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { store.addTag(t, to: pendingURLs) }
                    showNewTag = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

/// Opens Quick Look for an explicit set of URLs and reports index changes so
/// the grid selection can follow the user paging inside Quick Look.
enum QuickLookOpener {
    static func open(_ urls: [URL], startAt index: Int = 0,
                     onIndexChange: ((Int) -> Void)? = nil) {
        Holder.shared.urls = urls
        Holder.shared.onIndexChange = onIndexChange
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = Holder.shared
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
            panel.currentPreviewItemIndex = max(0, min(index, urls.count - 1))
            Holder.shared.observe(panel)   // after setting index, so no initial fire
        }
    }

    final class Holder: NSObject, QLPreviewPanelDataSource {
        static let shared = Holder()
        var urls: [URL] = []
        var onIndexChange: ((Int) -> Void)?
        private var observation: NSKeyValueObservation?

        func observe(_ panel: QLPreviewPanel) {
            observation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { panel, _ in
                let i = panel.currentPreviewItemIndex
                MainActor.assumeIsolated { Holder.shared.onIndexChange?(i) }
            }
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            urls[index] as NSURL
        }
    }
}
