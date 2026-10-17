import SwiftUI

/// Explore a source (feed, followed and own collections, search where the
/// account allows it, any collection) and save only the items you pick.
/// Nothing is downloaded until you save; previews load straight from the
/// service's image URLs.
struct SourceBrowserView: View {
    let pluginID: String
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var boards: BoardStore

    enum Location: Hashable {
        case scope(BrowseScope, query: String)
        case collection(SourceCollection)
    }

    @State private var history: [Location] = []
    @State private var collections: [SourceCollection] = []
    @State private var items: [SourceItem] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var selection: Set<String> = []
    @State private var saved: Set<String> = []
    @State private var searchText = ""
    @State private var pasted = ""
    @State private var nearby: [SourceCollection] = []
    @State private var detail: SourceItem?

    private var plugin: DiscoveredPlugin? { sources.plugin(pluginID) }
    private var info: SourceInfo? { plugin?.manifest.source }
    private var scopes: [BrowseScope] { sources.accounts[pluginID]?.browseScopes ?? [] }
    private var location: Location? { history.last }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                actionBar
            }
        }
        .navigationTitle(info.map { "Browse \($0.displayName)" } ?? "Browse")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(history.count < 2)
                .keyboardShortcut("[", modifiers: .command)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            sources.attach(to: store)
            if let plugin, sources.accounts[pluginID] == nil {
                await sources.checkAccount(plugin)
            }
            await refreshSaved()
            if !applyTarget(), history.isEmpty, let first = scopes.first(where: { $0.takesQuery != true }) {
                go(.scope(first, query: ""))
            }
        }
        .onChange(of: sources.browseTarget) { _ in
            _ = applyTarget()
        }
        .onChange(of: sources.finishedPull) { _ in
            Task { await refreshSaved() }
        }
        .sheet(item: $detail) { item in
            BrowseItemDetail(pluginID: pluginID, item: item, saved: saved.contains(item.remoteId),
                             open: { collection in
                                 detail = nil
                                 go(.collection(collection))
                             },
                             save: {
                                 detail = nil
                                 save([item.remoteId], toBoard: nil)
                             })
        }
    }

    /// Follow a request from a menu ("Browse in Overlap" on a synced collection).
    private func applyTarget() -> Bool {
        guard let target = sources.browseTarget, target.pluginID == pluginID,
              let collection = target.collection else {
            return false
        }
        sources.browseTarget = nil
        go(.collection(collection))
        return true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Explore") {
                ForEach(scopes) { scope in
                    Button {
                        go(.scope(scope, query: scope.takesQuery == true ? searchText : ""))
                    } label: {
                        Label(scope.label, systemImage: scope.symbol ?? "circle")
                    }
                    .buttonStyle(.plain)
                    .fontWeight(isCurrent(scope) ? .semibold : .regular)
                }
                if scopes.isEmpty {
                    Text(sources.accounts[pluginID]?.authenticated == false
                         ? "Sign in under Connected Services." : "Loading…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let synced = sources.links.filter { $0.pluginID == pluginID }
            if !synced.isEmpty {
                Section("Synced") {
                    ForEach(synced) { link in
                        Button(link.collection.title) { go(.collection(link.collection)) }
                            .buttonStyle(.plain)
                            .lineLimit(1)
                    }
                }
            }
            Section("Open a \(info?.noun ?? "collection")") {
                TextField("Paste a link or slug", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openPasted)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func isCurrent(_ scope: BrowseScope) -> Bool {
        if case .scope(let current, _) = location {
            return current.id == scope.id
        }
        return false
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch location {
            case .collection(let collection):
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title).font(.title3.bold()).lineLimit(1)
                    Text([collection.owner, collection.count.map { "\($0) items" },
                          info?.visibilityLabel(collection.visibility)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let page = collection.url, let url = URL(string: page) {
                    Button("Open on \(info?.displayName ?? "web")") { NSWorkspace.shared.open(url) }
                }
                Button("More by Owner") { loadOwnerCollections(collection) }
                Button(isSynced(collection) ? "Sync All" : "Import All") { importAll(collection) }
                    .disabled(sources.busy)
                    .help("Save every item and keep this \(info?.noun ?? "collection") synced")
            case .scope(let scope, _):
                if scope.takesQuery == true {
                    TextField("Search \(info?.displayName ?? "")", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { go(.scope(scope, query: searchText), replace: true) }
                } else {
                    Text(scope.label).font(.title3.bold())
                    Spacer()
                }
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            case nil:
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func isSynced(_ collection: SourceCollection) -> Bool {
        sources.links.contains { $0.pluginID == pluginID && $0.collection.id == collection.id }
    }

    // MARK: - Content

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    Text(error).foregroundStyle(.orange).padding(.top, 8)
                }
                if !nearby.isEmpty {
                    collectionStrip("Also by this owner", nearby)
                }
                if !collections.isEmpty {
                    collectionStrip(items.isEmpty ? "" : "\(info?.noun.capitalized ?? "Collection")s", collections,
                                    wrap: items.isEmpty)
                }
                if !items.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(items, id: \.remoteId) { item in
                            BrowseTile(item: item, selected: selection.contains(item.remoteId),
                                       saved: saved.contains(item.remoteId),
                                       showVia: !isCollectionLocation,
                                       openVia: { go(.collection($0)) })
                                .onTapGesture(count: 2) { detail = item }
                                .onTapGesture { toggle(item.remoteId) }
                        }
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if cursor != nil {
                    Button("Load More") { loadMore() }
                        .frame(maxWidth: .infinity)
                } else if items.isEmpty && collections.isEmpty && error == nil && location != nil {
                    Text("Nothing here.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(14)
        }
    }

    private var isCollectionLocation: Bool {
        if case .collection = location {
            return true
        }
        return false
    }

    @ViewBuilder
    private func collectionStrip(_ title: String, _ list: [SourceCollection], wrap: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            }
            if wrap {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(list) { collectionCard($0) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(list) { collectionCard($0).frame(width: 190) }
                    }
                }
            }
        }
    }

    private func collectionCard(_ collection: SourceCollection) -> some View {
        Button { go(.collection(collection)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(.callout.weight(.medium)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text([collection.owner, collection.count.map { "\($0) items" }].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if isSynced(collection) {
                    Label("Synced", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let activity = sources.activity {
                ProgressView().controlSize(.small)
                Text(activity).lineLimit(1)
            } else if let message = sources.lastError ?? sources.lastMessage {
                Text(message).lineLimit(1).foregroundStyle(.secondary)
            } else {
                Text("Click to pick, double-click for details. Nothing downloads until you save.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !selection.isEmpty {
                Button("Clear") { selection.removeAll() }
                Menu("Save & Add to Board") {
                    ForEach(boards.boards) { board in
                        Button(board.name) { save(Array(selection), toBoard: board.id) }
                    }
                }
                .disabled(boards.boards.isEmpty || sources.busy)
                .fixedSize()
                Button("Save \(selection.count)") { save(Array(selection), toBoard: nil) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sources.busy)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Navigation & loading

    private func go(_ next: Location, replace: Bool = false) {
        if replace, !history.isEmpty {
            history.removeLast()
        }
        if history.last != next {
            history.append(next)
        }
        reload()
    }

    private func goBack() {
        guard history.count > 1 else {
            return
        }
        history.removeLast()
        reload()
    }

    private func reload() {
        collections = []
        items = []
        cursor = nil
        nearby = []
        selection.removeAll()
        error = nil
        load(cursor: nil)
    }

    private func loadMore() {
        load(cursor: cursor)
    }

    private func load(cursor: String?) {
        guard let plugin, let location else {
            return
        }
        loading = true
        Task {
            let result: Result<SourceResponse, SourceError>
            switch location {
            case .scope(let scope, let query):
                if scope.takesQuery == true && query.isEmpty {
                    loading = false
                    return
                }
                result = await sources.browse(plugin, scope: scope.id, query: query, cursor: cursor)
            case .collection(let collection):
                result = await sources.browse(plugin, scope: "collection", collection: collection.id, cursor: cursor)
            }
            guard location == self.location else {
                return   // navigated away meanwhile
            }
            loading = false
            switch result {
            case .success(let page):
                let seenItems = Set(items.map(\.remoteId))
                items += (page.items ?? []).filter { !seenItems.contains($0.remoteId) }
                let seenCollections = Set(collections.map(\.id))
                collections += (page.collections ?? []).filter { !seenCollections.contains($0.id) }
                self.cursor = page.nextCursor
            case .failure(let failure):
                error = failure.localizedDescription
                self.cursor = nil
            }
        }
    }

    private func loadOwnerCollections(_ collection: SourceCollection) {
        guard let plugin else {
            return
        }
        Task {
            if case .success(let list) = await sources.related(plugin, collection: collection.id) {
                nearby = list
            }
        }
    }

    private func openPasted() {
        guard let plugin else {
            return
        }
        let text = pasted
        Task {
            switch await sources.resolve(text, plugin: plugin) {
            case .success(let collection):
                pasted = ""
                go(.collection(collection))
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func refreshSaved() async {
        if let plugin {
            saved = await sources.savedRemoteIds(plugin)
        }
    }

    // MARK: - Saving

    private func save(_ ids: [String], toBoard boardID: UUID?) {
        guard let plugin else {
            return
        }
        let byID = Dictionary(items.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
        let current: SourceCollection?
        if case .collection(let collection) = location {
            current = collection
        } else {
            current = nil
        }
        let picks = ids.compactMap { id -> SourceEngine.Pick? in
            guard let item = byID[id] else {
                return nil
            }
            return SourceEngine.Pick(item: item, collection: current ?? item.via ?? SourceEngine.savedCollection())
        }
        sources.save(picks, plugin: plugin) { files in
            selection.removeAll()
            saved.formUnion(ids)
            if let boardID {
                Task {
                    await boards.addFiles(files.map(\.path), to: boardID, undo: boards.undoManager(for: boardID))
                }
            }
        }
    }

    private func importAll(_ collection: SourceCollection) {
        guard let plugin else {
            return
        }
        if let link = sources.link(for: collection, plugin: plugin) {
            sources.sync(link)
        } else if let destination = sources.defaultDestination(for: collection, plugin: plugin) {
            sources.importCollection(collection, plugin: plugin, destination: destination, includeTextAndLinks: true)
        }
    }
}

extension SourceItem: Identifiable {
    var id: String { remoteId }
}

/// One remote item in the browse grid: preview, title, where it was seen.
private struct BrowseTile: View {
    let item: SourceItem
    let selected: Bool
    let saved: Bool
    let showVia: Bool
    let openVia: (SourceCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(5)
                        .help("Already in your library")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(item.title ?? item.kind.capitalized).font(.caption).lineLimit(1)
            if showVia, let via = item.via {
                Button(via.title) { openVia(via) }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        let background = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        if let link = item.previewURL, let url = URL(string: link) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    kindIcon.frame(maxWidth: .infinity, maxHeight: .infinity).background(background)
                default:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(background)
                }
            }
        } else if let text = item.text, !text.isEmpty {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(background)
        } else {
            kindIcon.frame(maxWidth: .infinity, maxHeight: .infinity).background(background)
        }
    }

    private var kindIcon: some View {
        let symbol: String
        switch item.kind {
        case "link", "embed":
            symbol = "link"
        case "text":
            symbol = "text.alignleft"
        case "file":
            symbol = "doc"
        default:
            symbol = "photo"
        }
        return Image(systemName: symbol).font(.title).foregroundStyle(.tertiary)
    }
}

/// Larger preview, description, and the other collections an item is in.
private struct BrowseItemDetail: View {
    let pluginID: String
    let item: SourceItem
    let saved: Bool
    let open: (SourceCollection) -> Void
    let save: () -> Void
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var related: [SourceCollection]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = item.previewURL, let url = URL(string: link) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                .frame(maxHeight: 360)
            }
            Text(item.title ?? item.kind.capitalized).font(.headline)
            if let author = item.author {
                Text("Added by \(author)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(item.description ?? item.text ?? "")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            Text("Also in").font(.caption.bold()).foregroundStyle(.secondary)
            if let related {
                if related.isEmpty {
                    Text("No other collections.").font(.caption).foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(related) { collection in
                            Button(collection.title) { open(collection) }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                if let page = item.url, let url = URL(string: page) {
                    Button("Open on Web") { NSWorkspace.shared.open(url) }
                }
                if let source = item.sourceURL, let url = URL(string: source) {
                    Button("Open Source") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saved ? "Saved" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saved || sources.busy)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task {
            guard let plugin = sources.plugin(pluginID) else {
                related = []
                return
            }
            switch await sources.related(plugin, remoteId: item.remoteId) {
            case .success(let list):
                related = list
            case .failure:
                related = []
            }
        }
    }
}
