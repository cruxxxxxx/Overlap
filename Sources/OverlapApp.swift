import SwiftUI

@main
struct OverlapApp: App {
    @StateObject private var store = TagStore(scope: defaultScope)

    static var defaultScope: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            TutorialHost { ContentView() }
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Overlap Tutorial") {
                    NotificationCenter.default.post(name: .overlapStartTutorial, object: nil)
                }
            }
            CommandMenu("Plugins") {
                let plugins = PluginRegistry.discover()
                    .sorted { $0.manifest.name < $1.manifest.name }
                if plugins.isEmpty {
                    Text("No plugins installed")
                } else {
                    ForEach(plugins) { p in
                        Toggle(p.manifest.name, isOn: Binding(
                            get: { !store.disabledPluginIDs.contains(p.id) },
                            set: { on in
                                if on { store.disabledPluginIDs.remove(p.id) }
                                else { store.disabledPluginIDs.insert(p.id) }
                            }))
                    }
                }
                Divider()
                Button(store.warmingUp ? "Warming Up Index…" : "Warm Up Suggestion Index") {
                    store.warmUpPlugins(force: true)
                }
                .disabled(store.warmingUp)
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
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TagStore
    @State private var showStats = false
    @State private var showPrivacy = false
    @State private var showSlideshow = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } detail: {
            ResultsGridView()
                // Thin warm-up strip on the DETAIL pane only, so it never covers
                // the sidebar's Tags/Queue/Explore picker.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if store.warmingUp {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.warmupProgress ?? "Preparing suggestions…")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.bar)
                        .overlay(Divider(), alignment: .bottom)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: store.warmingUp)
        }
        .toolbar {
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

                Button { store.showPreview.toggle() } label: {
                    Label("Preview", systemImage: store.showPreview
                          ? "rectangle.righthalf.inset.filled"
                          : "rectangle.righthalf.inset.filled")
                }
                .help("Toggle split preview pane")
                .background(store.showPreview ? Color.accentColor.opacity(0.25) : .clear)

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
