import SwiftUI

/// Sidebar "Saved" section: click a query to make it live; right-click to
/// rename, delete, or turn it into a board. Hidden while there are none.
struct SavedQueriesSection: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var boards: BoardStore
    @Environment(\.openWindow) private var openWindow
    @State private var renamingID: UUID?
    @State private var renameText = ""

    var body: some View {
        let queries = store.visibleSavedQueries
        if !queries.isEmpty {
            Section("Saved") {
                ForEach(queries) { query in
                    row(query)
                        .alert("Rename Query", isPresented: renamingBinding(query.id)) {
                            TextField("Name", text: $renameText)
                            Button("Rename") { store.renameSavedQuery(query.id, to: renameText) }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            }
        }
    }

    private func renamingBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { renamingID == id }, set: { shown in
            if !shown {
                renamingID = nil
            }
        })
    }

    private func row(_ query: SavedQuery) -> some View {
        Button { store.applySavedQuery(query.id) } label: {
            Label(query.name, systemImage: query.searchQuery == nil ? "bookmark" : "text.magnifyingglass")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(query.searchQuery.map { "Search “\($0)”" } ?? "Apply this query")
        .contextMenu {
            Button("Apply") { store.applySavedQuery(query.id) }
            Button("New Board from Query") {
                Task { @MainActor in
                    if let id = await boards.createFromQuery(query, store: store) {
                        openWindow(id: "board", value: id)
                    }
                }
            }
            Divider()
            Button("Rename…") {
                renameText = query.name
                renamingID = query.id
            }
            Button("Delete", role: .destructive) { store.deleteSavedQuery(query.id) }
        }
    }
}

/// Sidebar "Boards" section: every mood board, plus a row that boards the
/// current results.
struct BoardsSection: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var boards: BoardStore
    @Environment(\.openWindow) private var openWindow
    @State private var deletingID: UUID?

    var body: some View {
        Section("Boards") {
            ForEach(boards.boards) { board in
                Button { openWindow(id: "board", value: board.id) } label: {
                    HStack {
                        Label(board.name, systemImage: "rectangle.3.group")
                            .lineLimit(1)
                        Spacer()
                        Text("\(board.items.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open") { openWindow(id: "board", value: board.id) }
                    Divider()
                    Button("Delete Board…", role: .destructive) { deletingID = board.id }
                }
                .confirmationDialog("Delete “\(board.name)”?", isPresented: deletingBinding(board.id)) {
                    Button("Delete Board", role: .destructive) { boards.delete(board.id) }
                } message: {
                    Text("Only the board is deleted. Its files stay where they are.")
                }
            }
            NewBoardButton()
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private func deletingBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { deletingID == id }, set: { shown in
            if !shown {
                deletingID = nil
            }
        })
    }
}

/// "New Board from Results": boards the live results and opens the board.
/// Shared by the sidebar and the File menu.
struct NewBoardButton: View {
    @EnvironmentObject var store: TagStore
    @EnvironmentObject var boards: BoardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            Task { @MainActor in
                if let id = await boards.createFromResults(store) {
                    openWindow(id: "board", value: id)
                }
            }
        } label: {
            Label("New Board from Results", systemImage: "plus")
        }
        .disabled(store.results.isEmpty)
        .help("Lay the current results out on a new mood board (⌘⇧B)")
    }
}
