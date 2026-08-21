import SwiftUI

@main
struct TagVennApp: App {
    @StateObject private var store = TagStore(scope: defaultScope)

    static var defaultScope: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TagStore
    @State private var showStats = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } detail: {
            if store.viewStyle == .clusters {
                ClusterView()
            } else {
                ResultsGridView()
            }
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
                Button {
                    store.viewStyle = store.viewStyle == .clusters ? .grid : .clusters
                } label: {
                    Label("Clusters", systemImage: store.viewStyle == .clusters
                          ? "circle.grid.2x2.fill" : "circle.hexagongrid")
                }
                .help("Toggle cluster view")
                .background(store.viewStyle == .clusters ? Color.accentColor.opacity(0.25) : .clear)

                Button { showStats = true } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                .help("Library statistics")

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
        .navigationTitle("TagVenn")
        .sheet(isPresented: $showStats) { StatsView().environmentObject(store) }
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
