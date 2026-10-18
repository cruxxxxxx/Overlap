import SwiftUI

/// Remote mode's bar, in place of the query bar: where you are, search when
/// the service offers it, and the few actions that apply to the whole page.
struct RemoteBar: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var remote: RemoteBrowseModel
    @Binding var thumbSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Button { remote.back() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(remote.history.count < 2)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            title
            if showsSearch {
                TextField("Search \(remote.info?.displayName ?? "")", text: $remote.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { remote.search() }
            }
            Spacer()
            if remote.loading || remote.stillLoadingPreviews {
                ProgressView().controlSize(.small)
            }
            Text("\(store.results.count)")
                .font(.headline).monospacedDigit()
            Text(remote.hasMore ? "loaded" : "items").foregroundStyle(.secondary)
            Slider(value: $thumbSize, in: 90...280).frame(width: 110)
            if !remote.nearby.isEmpty {
                Menu {
                    ForEach(remote.nearby) { collection in
                        Button(collection.title) { remote.go(.collection(collection)) }
                    }
                } label: {
                    Image(systemName: "person.crop.rectangle.stack")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More from this owner")
            }
            if let page = remote.currentWebPage {
                Button { NSWorkspace.shared.open(page) } label: {
                    Image(systemName: "safari")
                }
                .help("Open on \(remote.info?.displayName ?? "the web")")
            }
            if case .collection = remote.location {
                Button(remote.currentIsSynced ? "Sync" : "Import All") { remote.importAll() }
                    .help(remote.currentIsSynced
                          ? "Fetch anything new"
                          : "Save every item and keep this \(remote.info?.noun ?? "collection") synced")
            }
            Button { remote.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
        }
        .padding(8)
    }

    private var showsSearch: Bool {
        if case .scope(let scope, _) = remote.location {
            return scope.takesQuery == true
        }
        return false
    }

    @ViewBuilder
    private var title: some View {
        switch remote.location {
        case .scope(let scope, _):
            Label(scope.label, systemImage: scope.symbol ?? "square.grid.2x2")
                .font(.headline)
        case .collection(let collection):
            VStack(alignment: .leading, spacing: 0) {
                Text(collection.title).font(.headline).lineLimit(1)
                Text([collection.owner, collection.count.map { "\($0) items" },
                      remote.info?.visibilityLabel(collection.visibility)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .connections(let item):
            Text("\(remote.info?.noun.capitalized ?? "Collection")s with “\(item.title ?? "this")”")
                .font(.headline).lineLimit(1)
        case nil:
            Text(remote.info?.displayName ?? "").font(.headline)
        }
    }
}

/// Right-click menu for a remote tile.
struct RemoteItemMenu: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var remote: RemoteBrowseModel
    let url: URL
    let targets: [URL]

    var body: some View {
        if remote.collection(at: url) != nil {
            Button("Open") { _ = remote.open(url) }
        } else {
            if let media = FileOrigin.media(of: url), let link = media.sourceLink {
                Button(media.openLabel) { NSWorkspace.shared.open(link) }
            }
            Button("Quick Look") { QuickLookOpener.open(targets) }
            Button(targets.count == 1 ? "Save to Library" : "Save \(targets.count) to Library") {
                remote.save(targets)
            }
            Menu("Save with Tag") {
                ForEach(store.tagCounts.keys.sorted(), id: \.self) { tag in
                    Button(tag) { store.addTag(tag, to: targets) }
                }
            }
            Button("Show \((remote.info?.noun ?? "collection").capitalized)s It's In") {
                remote.showConnections(of: url)
            }
        }
        if let page = remote.webPage(for: url) {
            Divider()
            Button("Open on \(remote.info?.displayName ?? "Web")") { NSWorkspace.shared.open(page) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.absoluteString, forType: .string)
            }
        }
    }
}

/// Which services the sidebar shows, as comma-separated plugin ids.
enum SidebarService {
    static let key = "sidebar.services"

    static func ids(_ stored: String) -> [String] {
        stored.split(separator: ",").map(String.init)
    }

    static func show(_ pluginID: String) {
        let current = ids(UserDefaults.standard.string(forKey: key) ?? "")
        if !current.contains(pluginID) {
            UserDefaults.standard.set((current + [pluginID]).joined(separator: ","), forKey: key)
        }
    }
}

/// Sidebar sections, below the tags: each shown service's places to browse.
/// Absent when none is switched on.
struct ConnectedServicesSection: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var remote: RemoteBrowseModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarService.key) private var shown = ""

    var body: some View {
        ForEach(SidebarService.ids(shown).compactMap(sources.plugin)) { plugin in
            Section(plugin.manifest.source?.displayName ?? plugin.manifest.name) {
                serviceRows(plugin)
            }
        }
    }

    @ViewBuilder
    private func serviceRows(_ plugin: DiscoveredPlugin) -> some View {
        let active = store.mode == .remote && remote.pluginID == plugin.id
        if sources.accounts[plugin.id]?.authenticated == false {
            Button("Sign in…") { openWindow(id: "sources") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else if sources.accounts[plugin.id] == nil {
            ProgressView().controlSize(.small)
                .task(id: plugin.id) {
                    await sources.checkAccount(plugin)
                }
        }
        ForEach(sources.accounts[plugin.id]?.browseScopes ?? []) { scope in
            row(scope.label, symbol: scope.symbol ?? "square.grid.2x2",
                selected: active && remote.isCurrent(scope)) {
                if scope.takesQuery == true, case .scope(let current, _)? = remote.location,
                   current.id == scope.id, active {
                    return
                }
                remote.open(pluginID: plugin.id, at: .scope(scope, query: scope.takesQuery == true ? remote.searchText : ""))
            }
        }
        ForEach(sources.links.filter { $0.pluginID == plugin.id }) { link in
            row(link.collection.title, symbol: "arrow.triangle.2.circlepath",
                selected: active && remote.isCurrent(link.collection)) {
                remote.open(pluginID: plugin.id, at: .collection(link.collection))
            }
        }
        OpenLinkRow(plugin: plugin)
    }

    private func row(_ title: String, symbol: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .fontWeight(selected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bottom of the sidebar: a small "Connected Services" menu that switches
/// each service's section on or off.
struct ServicesMenuBar: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var remote: RemoteBrowseModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarService.key) private var shown = ""

    var body: some View {
        if !sources.plugins.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Menu {
                        ForEach(sources.plugins) { plugin in
                            Toggle(plugin.manifest.source?.displayName ?? plugin.manifest.name,
                                   isOn: binding(for: plugin.id))
                        }
                        Divider()
                        Button("Manage Connected Services…") { openWindow(id: "sources") }
                    } label: {
                        Label("Connected Services", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private func binding(for pluginID: String) -> Binding<Bool> {
        Binding(
            get: { SidebarService.ids(shown).contains(pluginID) },
            set: { on in
                var ids = SidebarService.ids(shown).filter { $0 != pluginID }
                if on {
                    ids.append(pluginID)
                } else if store.mode == .remote && remote.pluginID == pluginID {
                    store.setMode(.tags)
                }
                shown = ids.joined(separator: ",")
            })
    }
}

/// Paste a collection's link (or slug) to open it.
private struct OpenLinkRow: View {
    @EnvironmentObject var remote: RemoteBrowseModel
    let plugin: DiscoveredPlugin
    @State private var showing = false
    @State private var text = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Button {
            failure = nil
            showing = true
        } label: {
            Label("Open Link…", systemImage: "link")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Paste a \(plugin.manifest.source?.noun ?? "collection") link", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onSubmit(open)
                    if working {
                        ProgressView().controlSize(.small)
                    }
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
        }
    }

    private func open() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return
        }
        working = true
        failure = nil
        Task {
            failure = await remote.openLink(input, pluginID: plugin.id)
            working = false
            if failure == nil {
                text = ""
                showing = false
            }
        }
    }
}
