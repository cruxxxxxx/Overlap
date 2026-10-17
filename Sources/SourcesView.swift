import SwiftUI

/// The Sources window: one section per source plugin (account, synced
/// collections), plus the import and send sheets that menus and boards open
/// through `SourceStore.route`.
struct SourcesView: View {
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var store: TagStore

    var body: some View {
        VStack(spacing: 0) {
            if sources.plugins.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sources.plugins) { plugin in
                            SourcePluginSection(plugin: plugin)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            sources.attach(to: store)
            sources.reloadPlugins()
        }
        .sheet(item: $sources.route) { route in
            routeSheet(route)
        }
    }

    @ViewBuilder
    private func routeSheet(_ route: SourceRoute) -> some View {
        switch route {
        case .importFrom(let pluginID):
            if let plugin = sources.plugin(pluginID) {
                ImportFromSourceSheet(plugin: plugin)
            }
        case .send(let pluginID, let urls, let label):
            if let plugin = sources.plugin(pluginID) {
                SendToSourceSheet(plugin: plugin, urls: urls, label: label)
            }
        case .linkBoard(let pluginID, let boardID, let boardName):
            if let plugin = sources.plugin(pluginID) {
                ImportFromSourceSheet(plugin: plugin, board: (boardID, boardName))
            }
        case .publishBoard(let pluginID, let boardID, let boardName, let urls):
            if let plugin = sources.plugin(pluginID) {
                PublishBoardSheet(plugin: plugin, boardID: boardID, boardName: boardName, urls: urls)
            }
        case .editCollection(let linkID):
            if let link = sources.link(id: linkID), let plugin = sources.plugin(link.pluginID) {
                EditCollectionSheet(plugin: plugin, link: link)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No source plugins installed").font(.headline)
            Text("A connected-service plugin links Overlap to an external image or web service.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let activity = sources.activity {
                ProgressView().controlSize(.small)
                Text(activity).lineLimit(1)
                Spacer()
                Button("Cancel") { sources.cancel() }
            } else if let error = sources.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2)
                Spacer()
            } else if let message = sources.lastMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).lineLimit(2)
                Spacer()
            } else {
                Text("Hidden and vault files are never sent to a source.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Account + synced collections for one provider.
private struct SourcePluginSection: View {
    let plugin: DiscoveredPlugin
    @EnvironmentObject var sources: SourceStore
    @Environment(\.openWindow) private var openWindow
    @State private var secretDrafts: [String: String] = [:]

    private var info: SourceInfo { plugin.manifest.source! }
    private var links: [SourceLink] { sources.links.filter { $0.pluginID == plugin.id } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                accountRows
                Divider()
                linkRows
                HStack {
                    Button("Import a \(info.noun.capitalized)…") {
                        sources.route = .importFrom(pluginID: plugin.id)
                    }
                    .disabled(sources.busy || !signedIn)
                    Button("Browse \(info.displayName)…") {
                        sources.requestBrowse(plugin.id)
                        openWindow(id: "source-browser", value: plugin.id)
                    }
                    .disabled(!signedIn)
                    Spacer()
                }
            }
            .padding(6)
        } label: {
            Text(info.displayName).font(.headline)
        }
        .task {
            if sources.accounts[plugin.id] == nil {
                await sources.checkAccount(plugin)
            }
        }
    }

    private var signedIn: Bool { sources.accounts[plugin.id]?.authenticated == true }

    @ViewBuilder
    private var accountRows: some View {
        HStack(spacing: 6) {
            if let account = sources.accounts[plugin.id] {
                Circle().fill(account.authenticated ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(account.authenticated ? "Signed in as \(account.name ?? "you")" : "Not signed in")
                if account.authenticated && account.canWrite == false {
                    Text("· read-only token, can't send").foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Checking account…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        ForEach(plugin.manifest.secrets ?? [], id: \.key) { secret in
            secretRow(secret)
        }
    }

    private func secretRow(_ secret: PluginSecret) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(sources.hasSecret(plugin, secret.key) ? "Saved — paste a new one to replace" : secret.label,
                            text: Binding(get: { secretDrafts[secret.key] ?? "" },
                                          set: { secretDrafts[secret.key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button("Save") {
                    sources.setSecret(secretDrafts[secret.key] ?? "", plugin: plugin, key: secret.key)
                    secretDrafts[secret.key] = ""
                }
                .disabled((secretDrafts[secret.key] ?? "").isEmpty)
                if sources.hasSecret(plugin, secret.key) {
                    Button("Sign Out") {
                        sources.setSecret("", plugin: plugin, key: secret.key)
                    }
                }
            }
            HStack(spacing: 4) {
                if let help = secret.help {
                    Text(help)
                }
                if let link = secret.url, let url = URL(string: link) {
                    Link("Create one", destination: url)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var linkRows: some View {
        Text("Synced \(info.noun)s").font(.caption.bold()).foregroundStyle(.secondary)
        if links.isEmpty {
            Text("None yet.").font(.caption).foregroundStyle(.tertiary)
        }
        ForEach(links) { link in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.collection.title)
                    Text(subtitle(link)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Sync Now") { sources.sync(link) }
                    .disabled(sources.busy || !signedIn)
                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: link.destination))
                    }
                    if let page = link.collection.url, let url = URL(string: page) {
                        Button("Open on \(info.displayName)") { NSWorkspace.shared.open(url) }
                    }
                    Button("Browse in Overlap") {
                        sources.requestBrowse(plugin.id, collection: link.collection)
                        openWindow(id: "source-browser", value: plugin.id)
                    }
                    if info.canEditCollection == true && link.collection.writable != false {
                        Button("Edit \(info.noun.capitalized)…") {
                            sources.route = .editCollection(linkID: link.id)
                        }
                    }
                    Divider()
                    Button("Stop Syncing") { sources.removeLink(link) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func subtitle(_ link: SourceLink) -> String {
        let folder = (link.destination as NSString).abbreviatingWithTildeInPath
        guard let last = link.lastSync else {
            return "\(folder) · never synced"
        }
        return "\(folder) · synced \(last.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Import

struct ImportFromSourceSheet: View {
    let plugin: DiscoveredPlugin
    /// Set when linking a board: the pull lands on that board too.
    var board: (id: UUID, name: String)? = nil
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var collections: [SourceCollection] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var pasted = ""
    @State private var selected: SourceCollection?
    @State private var destination: URL?
    @State private var includeTextAndLinks = true

    private var info: SourceInfo { plugin.manifest.source! }

    private var shown: [SourceCollection] {
        let all = selected.map { s in collections.contains(s) ? collections : [s] + collections } ?? collections
        guard !filter.isEmpty else {
            return all
        }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(board.map { "Link “\($0.name)” to a \(info.displayName) \(info.noun)" }
                 ?? "Import from \(info.displayName)")
                .font(.title3.bold())
            if board != nil {
                Text("The \(info.noun)'s files come onto the board. Syncing the board later adds new ones, and offers to send files you add to the board.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Filter your \(info.noun)s", text: $filter).textFieldStyle(.roundedBorder)
            }
            list
            HStack {
                TextField("Or paste a \(info.noun) link or slug", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(findPasted)
                Button("Find", action: findPasted).disabled(pasted.isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            destinationRow
            Toggle("Also import text and link blocks (as .md and .webloc files)", isOn: $includeTextAndLinks)
            if let selected {
                Text("Files are tagged “\(SourceEngine.tag(for: info, collectionTitle: selected.title))”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(board == nil ? "Import" : "Link & Import") {
                    guard let selected, let destination else {
                        return
                    }
                    sources.importCollection(selected, plugin: plugin, destination: destination,
                                             includeTextAndLinks: includeTextAndLinks, boardID: board?.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || destination == nil || sources.busy)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
        .task { await load() }
        .onChange(of: selected) { collection in
            guard let collection else {
                return
            }
            let existing = sources.link(for: collection, plugin: plugin)
            destination = existing.map { URL(fileURLWithPath: $0.destination) }
                ?? sources.defaultDestination(for: collection, plugin: plugin)
            includeTextAndLinks = existing?.includeTextAndLinks ?? true
        }
    }

    private var list: some View {
        List(shown, selection: $selected) { collection in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title)
                    Text(detail(collection)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if sources.link(for: collection, plugin: plugin) != nil {
                    Text("Synced").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tag(collection)
        }
        .overlay {
            if loading {
                ProgressView()
            } else if collections.isEmpty && error == nil {
                Text("No \(info.noun)s found.").foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 200)
    }

    private func detail(_ collection: SourceCollection) -> String {
        [collection.count.map { "\($0) items" }, info.visibilityLabel(collection.visibility), collection.owner]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var destinationRow: some View {
        HStack {
            Text("Save to:")
            Text(destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose a \(info.noun)")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(destination == nil ? .secondary : .primary)
            Spacer()
            Button("Change…", action: chooseDestination).disabled(selected == nil)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destination?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    private func load() async {
        loading = true
        switch await sources.collections(plugin) {
        case .success(let list):
            collections = list
        case .failure(let failure):
            error = failure.localizedDescription
        }
        loading = false
    }

    private func findPasted() {
        let text = pasted
        Task {
            switch await sources.resolve(text, plugin: plugin) {
            case .success(let collection):
                error = nil
                selected = collection
                pasted = ""
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }
}

// MARK: - Send

struct SendToSourceSheet: View {
    let plugin: DiscoveredPlugin
    let urls: [URL]
    let label: String
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var collections: [SourceCollection] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: SourceCollection?
    @State private var newTitle = ""
    @State private var newVisibility = ""
    @State private var creating = false

    private var info: SourceInfo { plugin.manifest.source! }
    private var gate: (allowed: [URL], dropped: Int) { sources.shareable(urls) }
    private var alreadyThere: Int {
        gate.allowed.filter { FileOrigin.remoteId(of: $0, plugin: plugin.id) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send \(label) to \(info.displayName)").font(.title3.bold())
            List(collections, selection: $selected) { collection in
                HStack {
                    Text(collection.title)
                    Spacer()
                    if let visibility = info.visibilityLabel(collection.visibility) {
                        Text(visibility).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(collection)
            }
            .overlay {
                if loading {
                    ProgressView()
                }
            }
            .frame(minHeight: 180)
            if info.canCreateCollection == true {
                newCollectionRow
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            summary
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send \(gate.allowed.count)") {
                    guard let selected else {
                        return
                    }
                    sources.push(gate.allowed, to: selected, plugin: plugin)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || gate.allowed.isEmpty || sources.busy)
            }
        }
        .padding(16)
        .frame(width: 500, height: 520)
        .task { await load() }
    }

    private var newCollectionRow: some View {
        HStack {
            TextField("New \(info.noun) name", text: $newTitle).textFieldStyle(.roundedBorder)
            if let choices = info.visibilities, !choices.isEmpty {
                Picker("", selection: $newVisibility) {
                    ForEach(choices) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Button("Create") { create() }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || creating)
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selected {
                Text("\(gate.allowed.count) file\(gate.allowed.count == 1 ? "" : "s") → “\(selected.title)”")
                    .bold()
                if info.isShared(selected.visibility) {
                    Text("This \(info.noun) is \(info.visibilityLabel(selected.visibility)?.lowercased() ?? "shared"): others can see what you send.")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Choose a \(info.noun).").foregroundStyle(.secondary)
            }
            if alreadyThere > 0 {
                Text("\(alreadyThere) already on \(info.displayName) will be connected, not uploaded again.")
                    .foregroundStyle(.secondary)
            }
            if gate.dropped > 0 {
                Text("\(gate.dropped) hidden or vault file\(gate.dropped == 1 ? "" : "s") left out.")
                    .foregroundStyle(.secondary)
            }
            Text("Your Overlap tags stay on this Mac.").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func load() async {
        loading = true
        if newVisibility.isEmpty {
            newVisibility = info.mostPrivate?.id ?? ""
        }
        switch await sources.collections(plugin) {
        case .success(let list):
            collections = list.filter { $0.writable != false }
        case .failure(let failure):
            error = failure.localizedDescription
        }
        loading = false
    }

    private func create() {
        creating = true
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        let visibility = info.visibilities?.isEmpty == false ? newVisibility : nil
        Task {
            switch await sources.createCollection(title, visibility: visibility, plugin: plugin) {
            case .success(let collection):
                collections.insert(collection, at: 0)
                selected = collection
                newTitle = ""
                error = nil
            case .failure(let failure):
                error = failure.localizedDescription
            }
            creating = false
        }
    }
}

// MARK: - Menu

/// The Sources menu: per provider, import and send; then the Sources window.
struct SourceMenuItems: View {
    @EnvironmentObject var sources: SourceStore
    @EnvironmentObject var store: TagStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if sources.plugins.isEmpty {
            Text("No source plugins installed")
        }
        ForEach(sources.plugins) { plugin in
            let name = plugin.manifest.source?.displayName ?? plugin.manifest.name
            Button("Browse \(name)…") {
                sources.requestBrowse(plugin.id)
                openWindow(id: "source-browser", value: plugin.id)
            }
            Button("Import from \(name)…") {
                show(.importFrom(pluginID: plugin.id))
            }
            if plugin.manifest.source?.canPush == true {
                Button("Send Selection to \(name)…") {
                    let urls = store.selectedURLs()
                    show(.send(pluginID: plugin.id, urls: urls, label: "\(urls.count) Selected"))
                }
                .disabled(store.selection.isEmpty)
                Button("Send Results to \(name)…") {
                    let urls = store.results.map(\.url)
                    show(.send(pluginID: plugin.id, urls: urls, label: "\(urls.count) Results"))
                }
                .disabled(store.results.isEmpty)
            }
            Divider()
        }
        Button("Connected Services…") {
            openWindow(id: "sources")
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])
    }

    private func show(_ route: SourceRoute) {
        openWindow(id: "sources")
        sources.route = route
    }
}
