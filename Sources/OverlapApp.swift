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
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TagStore
    @State private var showStats = false
    @State private var showPrivacy = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } detail: {
            ResultsGridView()
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
            }
        }
        .navigationTitle("Overlap")
        .sheet(isPresented: $showStats) { StatsView().environmentObject(store) }
        .sheet(isPresented: $showPrivacy) { PrivacyView().environmentObject(store) }
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
