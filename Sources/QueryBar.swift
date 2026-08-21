import SwiftUI

/// THE query bar — the single readout and editor of the current query.
/// Every other surface (sidebar tri-state, Explore blobs, Venn regions) is a
/// different way of writing to the same state this bar displays.
///
///   [Match ▾] [+A] [−B] … | N files | sort | size | Clear
///
/// Chip click cycles include → exclude → off (same language as the sidebar
/// dots); the small × removes the tag outright.
struct QueryBar: View {
    @EnvironmentObject var store: TagStore
    @Binding var thumbSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            matchMenu
            chips
            Spacer()
            Text("\(store.results.count)")
                .font(.headline).monospacedDigit()
            Text("files").foregroundStyle(.secondary)
            SortMenu()
            Slider(value: $thumbSize, in: 90...280).frame(width: 110)
            Button("Clear") { store.clearQuery() }
                .disabled(store.querySets.isEmpty && store.queryExcludes.isEmpty)
        }
        .padding(8)
    }

    // MARK: Match menu

    private var matchLabel: String {
        switch store.matchMode {
        case .all: return "All"
        case .any: return "Any"
        case .only: return "Exact"
        case .regions: return "Venn"
        }
    }

    private var matchMenu: some View {
        Menu {
            Button { store.setMatchMode(.all) } label: { row("All", "has every tag", on: store.matchMode == .all) }
            Button { store.setMatchMode(.any) } label: { row("Any", "has at least one", on: store.matchMode == .any) }
            Button { store.setMatchMode(.only) } label: { row("Exact", "these tags and nothing else", on: store.matchMode == .only) }
            if store.matchMode == .regions {
                Divider()
                Button("Clear painted regions") { store.setMatchMode(.all) }
            }
        } label: {
            Label(matchLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How included tags combine. Painting Venn regions in Explore switches this to Venn.")
    }

    private func row(_ title: String, _ subtitle: String, on: Bool) -> some View {
        HStack {
            Text("\(title) — \(subtitle)")
            if on { Image(systemName: "checkmark") }
        }
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.querySets, id: \.self) { tag in
                    queryChip(tag, baseRole: store.regionRole(tag) ?? .required)
                }
                ForEach(store.activeExcludes, id: \.self) { tag in
                    queryChip(tag, baseRole: .excluded)
                }
            }
        }
    }

    private func queryChip(_ tag: String, baseRole: RegionRole) -> some View {
        let color: Color
        let symbol: String
        switch baseRole {
        case .required: color = .green; symbol = "plus"
        case .excluded: color = .red; symbol = "minus"
        case .mixed:    color = .gray; symbol = "plusminus"
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(tag).font(.caption)
                .strikethrough(baseRole == .excluded)
            Button { store.clear(tag) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from query")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.25), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.6)))
        .onTapGesture { store.cycle(tag) }
        .help("Click cycles include → exclude → off")
    }
}

/// Sort menu, shared by the query bar and the queue bar.
struct SortMenu: View {
    @EnvironmentObject var store: TagStore

    var body: some View {
        Menu {
            ForEach(SortKey.allCases) { key in
                Button { store.setSortKey(key) } label: {
                    HStack {
                        Text(key.rawValue)
                        if store.sortKey == key { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button { store.setSortAscending(true) } label: {
                HStack { Text("Ascending"); if store.sortAscending { Image(systemName: "checkmark") } }
            }
            Button { store.setSortAscending(false) } label: {
                HStack { Text("Descending"); if !store.sortAscending { Image(systemName: "checkmark") } }
            }
        } label: {
            Label(store.sortKey.rawValue,
                  systemImage: store.sortAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
