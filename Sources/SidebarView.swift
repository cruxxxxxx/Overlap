import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension TagNode {
    var childrenOrNil: [TagNode]? { children.isEmpty ? nil : children }
}

struct SidebarView: View {
    @EnvironmentObject var store: TagStore
    @State private var search = ""
    @State private var renaming: TagNode?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newTagText = ""
    @State private var mergingNode: TagNode?
    @State private var mergeFilter = ""

    private var modeBinding: Binding<LibraryMode> {
        Binding(get: { store.mode }, set: { store.setMode($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: modeBinding) {
                Text("Tags").tag(LibraryMode.tags)
                Text("Queue").tag(LibraryMode.queue)
                Text("Explore").tag(LibraryMode.explore)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if store.mode == .explore {
                ExploreView()
            } else {
                if store.mode == .queue {
                    queueControls
                    Divider()
                }
                searchHeader
                Divider()
                List {
                    if store.mode == .queue {
                        Text("Select images, then click a tag to apply")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(orderedTree) { top in
                        topNode(top)
                    }
                    .onMove { offsets, dest in
                        guard search.isEmpty else { return }
                        store.reorderTopTags(orderedTree.map(\.name), from: offsets, to: dest)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .sheet(item: $renaming) { node in renameSheet(node) }
        .sheet(item: $mergingNode) { node in mergeSheet(node) }
        .sheet(isPresented: $creating) { createSheet }
        .onReceive(NotificationCenter.default.publisher(for: .tvRenameTag)) { note in
            if let n = note.object as? TagNode {
                renameText = n.fullPath
                renaming = n
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvNewSubtag)) { note in
            if let n = note.object as? TagNode {
                newTagText = n.fullPath + "/"
                creating = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvMergeTag)) { note in
            if let n = note.object as? TagNode { mergeFilter = ""; mergingNode = n }
        }
    }

    private func mergeSheet(_ node: TagNode) -> some View {
        let targets = store.tagCounts.keys
            .filter { $0 != node.fullPath }
            .filter { mergeFilter.isEmpty || $0.localizedCaseInsensitiveContains(mergeFilter) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Merge “\(node.fullPath)” into…").font(.headline)
            Text("All files tagged “\(node.fullPath)” get the chosen tag instead.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Filter tags", text: $mergeFilter).frame(width: 300)
            List(targets, id: \.self) { tag in
                Button {
                    store.mergeTag(node.fullPath, into: tag)
                    mergingNode = nil
                } label: {
                    HStack {
                        Text(tag)
                        Spacer()
                        Text("\(store.tagCounts[tag] ?? 0)").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 300, height: 240)
            HStack { Spacer(); Button("Cancel") { mergingNode = nil } }
        }
        .padding(20)
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tag").font(.headline)
            Text("Use “/” for subtags, e.g. cat/Fashion or type/Cover.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("cat/Fashion", text: $newTagText).frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }
                Button("Create") {
                    store.addKnownTag(newTagText)
                    creating = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Queue controls

    private var queueControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watched Folders").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { addFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a folder to watch")
            }
            ForEach(store.queueFolders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { store.removeQueueFolder(folder) } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless)
                }
                .font(.caption)
            }
            Toggle("Include subfolders", isOn: Binding(
                get: { store.queueRecursive },
                set: { store.setQueueRecursive($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            HStack {
                Button("Rescan") { store.scanQueue() }
                Spacer()
                Text("\(store.queueItems.count) untagged")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button {
                store.applyQueue()
            } label: {
                Text("Apply \(store.taggedQueueCount) → Library")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.taggedQueueCount == 0)
            .help("Move tagged items into the library folder")
        }
        .padding(8)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.addQueueFolder(url)
        }
    }

    // MARK: Tag tree

    private var searchHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter tags", text: $search)
                .textFieldStyle(.plain)
            if store.isIndexing { ProgressView().controlSize(.mini) }
            Button { newTagText = ""; creating = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New tag")
        }
        .padding(8)
    }

    private var filteredTree: [TagNode] {
        guard !search.isEmpty else { return store.tagTree }
        return store.tagTree.compactMap { prune($0, query: search.lowercased()) }
    }

    /// Top-level nodes ordered by the user's custom order, then A→Z.
    private var orderedTree: [TagNode] {
        let idx = Dictionary(uniqueKeysWithValues: store.tagOrder.enumerated().map { ($1, $0) })
        return filteredTree.sorted {
            let a = idx[$0.name] ?? Int.max
            let b = idx[$1.name] ?? Int.max
            return a != b ? a < b
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func topNode(_ top: TagNode) -> some View {
        if top.children.isEmpty {
            TagRow(node: top)
        } else {
            DisclosureGroup {
                OutlineGroup(top.children, children: \.childrenOrNil) { node in
                    TagRow(node: node)
                }
            } label: {
                TagRow(node: top)
            }
        }
    }

    private func prune(_ node: TagNode, query: String) -> TagNode? {
        let keptChildren = node.children.compactMap { prune($0, query: query) }
        let selfMatch = node.name.lowercased().contains(query)
        if selfMatch || !keptChildren.isEmpty {
            let copy = TagNode(fullPath: node.fullPath, name: node.name, count: node.count)
            copy.children = keptChildren
            return copy
        }
        return nil
    }

    private func renameSheet(_ node: TagNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(node.fullPath)”").font(.headline)
            TextField("New name", text: $renameText).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") {
                    let new = renameText.trimmingCharacters(in: .whitespaces)
                    if !new.isEmpty { store.renameTagEverywhere(node.fullPath, to: new) }
                    renaming = nil
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct TagRow: View {
    @EnvironmentObject var store: TagStore
    let node: TagNode
    @State private var dropTargeted = false

    private var state: TriState { store.effectiveState(for: node.fullPath) }

    private var dotColor: Color {
        if store.mode == .queue { return Color(nsColor: .tertiaryLabelColor) }
        switch state {
        case .off: return Color(nsColor: .tertiaryLabelColor)
        case .include: return .green
        case .exclude: return .red
        }
    }

    var body: some View {
        Button {
            if store.mode == .queue {
                store.addTag(node.fullPath, to: store.selectedURLs())
            } else {
                store.cycle(node.fullPath)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(node.name)
                    .strikethrough(store.mode == .tags && state == .exclude)
                Spacer()
                Text("\(node.count)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .background(dropTargeted ? Color.accentColor.opacity(0.25) : .clear)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            applyTagToDropped(providers)
            return true
        }
        .contextMenu {
            if store.mode == .tags {
                Button("Include") { store.set(node.fullPath, to: .include) }
                Button("Exclude") { store.set(node.fullPath, to: .exclude) }
                Button("Off") { store.set(node.fullPath, to: .off) }
            } else {
                Button("Apply to Selection") {
                    store.addTag(node.fullPath, to: store.selectedURLs())
                }
            }
            Divider()
            Menu("Default in Queries") {
                let cur = store.defaultStance(node.fullPath)
                Button(cur == .off ? "✓ None" : "None") {
                    store.setDefault(node.fullPath, .off)
                }
                Button(cur == .include ? "✓ Always Include" : "Always Include") {
                    store.setDefault(node.fullPath, .include)
                }
                Button(cur == .exclude ? "✓ Always Exclude" : "Always Exclude") {
                    store.setDefault(node.fullPath, .exclude)
                }
            }
            if store.isHiddenTag(node.fullPath) {
                Button("Unhide Tag") { store.setHidden(node.fullPath, false) }
            } else {
                Button("Hide Tag") { store.setHidden(node.fullPath, true) }
            }
            Divider()
            Button("New Subtag…") {
                NotificationCenter.default.post(name: .tvNewSubtag, object: node)
            }
            Button("Rename Tag…") {
                NotificationCenter.default.post(name: .tvRenameTag, object: node)
            }
            Button("Merge Into…") {
                NotificationCenter.default.post(name: .tvMergeTag, object: node)
            }
            Button("Delete Tag Everywhere", role: .destructive) {
                store.deleteTagEverywhere(node.fullPath)
            }
        }
    }

    private func applyTagToDropped(_ providers: [NSItemProvider]) {
        let tag = node.fullPath
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                if let u = obj as? URL { urls.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            // If the dragged image is part of the current selection, tag the
            // whole selection (SwiftUI drag only carries the one grabbed item).
            let inSelection = urls.contains { store.selection.contains($0.path) }
            let targets = inSelection ? store.selectedURLs() : urls
            store.addTag(tag, to: targets.isEmpty ? urls : targets)
        }
    }
}

extension Notification.Name {
    static let tvRenameTag = Notification.Name("tvRenameTag")
    static let tvNewSubtag = Notification.Name("tvNewSubtag")
    static let tvMergeTag = Notification.Name("tvMergeTag")
}
