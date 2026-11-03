import SwiftUI
import Quartz

@main
struct OverlapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TagStore(scope: defaultScope)
    @StateObject private var boards = BoardStore()
    @StateObject private var sources = SourceStore()
    @StateObject private var remote = RemoteBrowseModel()
    @StateObject private var explore = ExploreModel()

    static var defaultScope: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            TutorialHost { ContentView() }
                .environmentObject(store)
                .environmentObject(boards)
                .environmentObject(sources)
                .environmentObject(remote)
                .environmentObject(explore)
                .frame(minWidth: 900, minHeight: 560)
                .background(MainWindowReader())
                .onAppear {
                    boards.attach(to: store)
                    sources.attach(to: store)
                    remote.attach(sources: sources, tags: store)
                    explore.attach(to: store)
                }
        }
        .commands {
            // Our items take the New slot: an empty File menu gets dropped
            // from the menu bar altogether.
            CommandGroup(replacing: .newItem) {
                Button("Open Query…") { store.openQueryFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Export Results as Folder…") { store.exportResults() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.results.isEmpty || store.exportProgress != nil)
                FindDuplicatesMenuItem()
                Divider()
                BoardMenuItems()
                    .environmentObject(store)
                    .environmentObject(boards)
            }
            CommandGroup(before: .toolbar) {
                LibraryTabMenuItems()
                    .environmentObject(store)
                Divider()
            }
            CommandGroup(replacing: .undoRedo) {
                BoardUndoMenuItems()
                    .environmentObject(boards)
            }
            CommandGroup(replacing: .help) {
                Button("Overlap Tutorial") {
                    NotificationCenter.default.post(name: .overlapStartTutorial, object: nil)
                }
            }
            CommandMenu("Sources") {
                SourceMenuItems()
                    .environmentObject(store)
                    .environmentObject(sources)
            }
            CommandMenu("Plugins") {
                PluginToggleItems()
                    .environmentObject(store)
                Divider()
                Button("Plugin Settings…") {
                    NotificationCenter.default.post(name: .overlapShowPluginSettings, object: nil)
                }
                Button(store.warmingUp ? "Warming Up Index…" : "Warm Up Suggestion Index") {
                    store.warmUpPlugins(force: true)
                }
                .disabled(store.warmingUp)
                Button(store.searchIndexing ? "Indexing Search…" : "Rebuild Search Index") {
                    store.warmUpSearchIndex(force: true)
                }
                .disabled(store.searchIndexing || !store.searchAvailable)
                Divider()
                Button("Open Plugins Folder") {
                    if let dir = PluginRegistry.userPluginsDir() {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
                Button("Open Plugin Cache & Config") {
                    let dir = FileManager.default
                        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Overlap/PluginCache", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
        }

        Window("Duplicates", id: "duplicates") {
            DuplicatesView()
                .environmentObject(store)
        }

        Window("Connected Services", id: "sources") {
            SourcesView()
                .environmentObject(store)
                .environmentObject(sources)
        }

        WindowGroup("Board", id: "board", for: UUID.self) { $boardID in
            BoardWindow(boardID: boardID)
                .environmentObject(store)
                .environmentObject(boards)
                .environmentObject(sources)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear { boards.attach(to: store) }
        }

        Settings {
            OverlapSettingsView()
        }
    }
}

/// Edit › Undo / Redo: a board window's own history when one is in front,
/// otherwise the usual responder-chain undo (text fields and the like).
struct BoardUndoMenuItems: View {
    @EnvironmentObject var boards: BoardStore

    var body: some View {
        Button("Undo") { perform(redo: false) }
            .keyboardShortcut("z", modifiers: .command)
        Button("Redo") { perform(redo: true) }
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    private func perform(redo: Bool) {
        if let id = boards.boardID(in: NSApp.keyWindow) {
            let manager = boards.undoManager(for: id)
            if redo {
                manager.redo()
            } else {
                manager.undo()
            }
        } else {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        }
    }
}

/// Plugins menu: one on/off toggle per plugin, grouped by what it does.
struct PluginToggleItems: View {
    @EnvironmentObject var store: TagStore

    private enum Group: CaseIterable {
        case services, suggestions, search

        var title: String {
            switch self {
            case .services:
                return "Connected Services"
            case .suggestions:
                return "Tag Suggestions"
            case .search:
                return "Search"
            }
        }

        func contains(_ plugin: DiscoveredPlugin) -> Bool {
            switch self {
            case .services:
                return plugin.isSource
            case .suggestions:
                return plugin.supports("suggest")
            case .search:
                return plugin.supports("search")
            }
        }
    }

    var body: some View {
        let plugins = PluginRegistry.discover().sorted { $0.manifest.name < $1.manifest.name }
        if plugins.isEmpty {
            Text("No plugins installed")
        }
        ForEach(Group.allCases.filter { group in plugins.contains(where: group.contains) }, id: \.title) { group in
            Section(group.title) {
                ForEach(plugins.filter(group.contains)) { plugin in
                    Toggle(plugin.manifest.name, isOn: Binding(
                        get: { !store.disabledPluginIDs.contains(plugin.id) },
                        set: { on in
                            if on {
                                store.disabledPluginIDs.remove(plugin.id)
                            } else {
                                store.disabledPluginIDs.insert(plugin.id)
                            }
                        }))
                }
            }
        }
    }
}

/// File-menu board commands: board the current results, open a board.
struct BoardMenuItems: View {
    @EnvironmentObject var boards: BoardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NewBoardButton()
            .keyboardShortcut("b", modifiers: [.command, .shift])
        Menu("Open Board") {
            if boards.boards.isEmpty {
                Text("No boards")
            } else {
                ForEach(boards.boards) { board in
                    Button(board.name) { openWindow(id: "board", value: board.id) }
                }
            }
        }
    }
}

/// Quitting while revealed must close the vault first. Do it after the
/// windows are gone, so ⌘Q feels instant instead of waiting on hdiutil.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard VaultDisk.isAttached else {
            return .terminateNow
        }
        for window in sender.windows {
            window.orderOut(nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            VaultDisk.detach()
            QuickLookCache.resetIfVaultFilesPreviewed()
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let overlapShowPluginSettings = Notification.Name("overlapShowPluginSettings")
}

struct ContentView: View {
    @EnvironmentObject var store: TagStore
    @State private var showStats = false
    @State private var showPrivacy = false
    @State private var showSlideshow = false
    @State private var showPluginSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } detail: {
            ResultsGridView()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                LibraryTabPicker()
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    chooseScope()
                } label: {
                    Label(store.scopeURL.lastPathComponent, systemImage: "folder")
                }
                .help("Choose the folder to search")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showStats = true } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                .help("Library statistics")

                Menu {
                    Button("Privacy & Hidden Tags…") { showPrivacy = true }
                    if store.revealed {
                        Button("Lock Now") { store.lock() }
                    }
                } label: {
                    Label("Hidden", systemImage: store.revealed ? "lock.open.fill" : "lock.fill")
                } primaryAction: {
                    if store.revealed { store.lock() } else { showPrivacy = true }
                }
                .help(store.revealed ? "Hidden tags revealed — click to lock"
                                     : "Reveal or manage hidden tags")
                .background(store.revealed ? Color.orange.opacity(0.25) : .clear)

                PreviewLayoutButton()

                Button { store.performUndo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .help(store.undoName.map { "Undo \($0)" } ?? "Undo")
                .disabled(!store.canUndo)

                Button { store.performRedo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .help(store.redoName.map { "Redo \($0)" } ?? "Redo")
                .disabled(!store.canRedo)

                Button {
                    let sel = store.selectedURLs()
                    let urls = sel.isEmpty ? store.results.map(\.url) : sel
                    if !urls.isEmpty { QuickLookOpener.open(urls) }
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .help("Quick Look selection (or Space)")
                .disabled(store.results.isEmpty)

                Button { showSlideshow = true } label: {
                    Label("Slideshow", systemImage: "play.rectangle")
                }
                .help("Play the current results as a slideshow")
                .disabled(store.results.isEmpty)
            }
        }
        .navigationTitle("Overlap")
        .onChange(of: store.revealed) { revealed in
            // Locking must not leave a hidden file on screen.
            if !revealed {
                showSlideshow = false
                if QLPreviewPanel.sharedPreviewPanelExists() {
                    QLPreviewPanel.shared()?.orderOut(nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlapShowPluginSettings)) { _ in
            showPluginSettings = true
        }
        .sheet(isPresented: $showPluginSettings) {
            PluginSettingsView().environmentObject(store)
        }
        .sheet(isPresented: $showStats) { StatsView().environmentObject(store) }
        .sheet(isPresented: $showPrivacy) { PrivacyView().environmentObject(store) }
        .sheet(isPresented: $showSlideshow) {
            let start = store.results.firstIndex { store.selection.contains($0.id) } ?? 0
            SlideshowView(items: store.results, startAt: start)
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 620)
        }
    }

    private func chooseScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.scopeURL
        if panel.runModal() == .OK, let url = panel.url {
            store.setScope(url)
        }
    }
}

/// One preview button: click steps off → beside → on top (carousel); the
/// menu picks one directly.
struct PreviewLayoutButton: View {
    @EnvironmentObject var store: TagStore

    var body: some View {
        let layout = store.previewLayout
        Menu {
            ForEach(PreviewLayout.allCases, id: \.self) { choice in
                Button { store.previewLayout = choice } label: {
                    HStack {
                        Text(choice.title)
                        if choice == layout { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label("Preview", systemImage: layout.symbol)
        } primaryAction: {
            store.previewLayout = layout.next
        }
        .help("\(layout.title). Click for \(layout.next.title.lowercased()); hold for the menu.")
        .background(layout == .off ? Color.clear : Color.accentColor.opacity(0.25))
    }
}

/// The main window's two places. Tags and Query are the Library's sidebar
/// switch; Explore is a button on its results bar.
enum LibraryTab: Hashable {
    case library, queue

    static func of(_ mode: LibraryMode) -> LibraryTab? {
        switch mode {
        case .tags, .find, .explore:
            return .library
        case .queue:
            return .queue
        case .remote:
            return nil
        }
    }
}

extension TagStore {
    func show(_ tab: LibraryTab) {
        switch tab {
        case .library:
            showLibrary()
        case .queue:
            setMode(.queue)
        }
    }
}

/// Library / Queue in the middle of the toolbar: words by default, icons when
/// Settings turns the labels off.
struct LibraryTabPicker: View {
    @EnvironmentObject var store: TagStore
    @AppStorage(LibraryTabPicker.labelsKey) private var showLabels = true

    static let labelsKey = "toolbarTabLabels"

    var body: some View {
        Picker("View", selection: Binding(get: { LibraryTab.of(store.mode) },
                                          set: { if let tab = $0 { store.show(tab) } })) {
            tab(.library, "Library", "photo.on.rectangle")
            tab(.queue, queueTitle, "tray")
        }
        .pickerStyle(.segmented)
        .help("Library (⌘1), Queue (⌘2)")
        .tutorialAnchor(.modePicker)
    }

    private var queueTitle: String {
        store.queueItems.isEmpty ? "Queue" : "Queue · \(store.queueItems.count)"
    }

    @ViewBuilder
    private func tab(_ tab: LibraryTab, _ title: String, _ symbol: String) -> some View {
        if showLabels {
            Text(title).tag(LibraryTab?.some(tab))
        } else {
            Image(systemName: symbol)
                .accessibilityLabel(title)
                .tag(LibraryTab?.some(tab))
        }
    }
}

/// View menu: switch tabs from the keyboard.
struct LibraryTabMenuItems: View {
    @EnvironmentObject var store: TagStore

    var body: some View {
        Button("Library") { store.show(.library) }
            .keyboardShortcut("1", modifiers: .command)
        Button("Queue") { store.show(.queue) }
            .keyboardShortcut("2", modifiers: .command)
        Button(store.mode == .explore ? "Stop Exploring" : "Explore") {
            if store.mode == .explore {
                store.showTagsTab()
            } else {
                store.setMode(.explore)
            }
        }
        .keyboardShortcut("3", modifiers: .command)
        Button(store.mode == .find ? "Show Tags" : "Show Query") {
            store.setTagsAsDiagram(store.mode != .find)
        }
        .keyboardShortcut("d", modifiers: .command)
    }
}

struct FindDuplicatesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Find Duplicates…") { openWindow(id: "duplicates") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
