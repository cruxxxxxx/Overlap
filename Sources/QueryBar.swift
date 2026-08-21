import SwiftUI

/// THE query bar — the single readout and editor of the current query.
/// Chips render per diagram in bracketed segments joined by AND; the active
/// diagram (where new tags land) has an accent border. Excludes trail after.
///
///   [Match ▾] ( +A  +B )  AND  ( +C )  −D | N files | sort | size | Clear
struct QueryBar: View {
    @EnvironmentObject var store: TagStore
    @Binding var thumbSize: CGFloat

    private var isEmptyQuery: Bool {
        store.groups.allSatisfy { $0.sets.isEmpty } && store.queryExcludes.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            matchMenu
            segments
            Spacer()
            Text("\(store.results.count)")
                .font(.headline).monospacedDigit()
            Text("files").foregroundStyle(.secondary)
            SortMenu()
            Slider(value: $thumbSize, in: 90...280).frame(width: 110)
            Button("Clear") { store.clearQuery() }
                .disabled(isEmptyQuery)
        }
        .padding(8)
    }

    // MARK: Match menu (applies to the active diagram)

    private var matchLabel: String {
        let g = store.activeGroup
        if !g.regions.isEmpty { return "Venn" }
        switch g.mode {
        case .all: return "All"
        case .any: return "Any"
        case .only: return "Exact"
        }
    }

    private var matchMenu: some View {
        let g = store.activeGroup
        return Menu {
            Button { store.setGroupMode(g.id, .all) } label: {
                row("All", "has every set", on: g.regions.isEmpty && g.mode == .all)
            }
            Button { store.setGroupMode(g.id, .any) } label: {
                row("Any", "has at least one", on: g.regions.isEmpty && g.mode == .any)
            }
            if store.groups.count == 1 {
                Button { store.setGroupMode(g.id, .only) } label: {
                    row("Exact", "these tags and nothing else", on: g.regions.isEmpty && g.mode == .only)
                }
            }
            if !g.regions.isEmpty {
                Divider()
                Button("Clear painted regions") { store.clearRegions(group: g.id) }
            }
        } label: {
            Label(matchLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How the active diagram's sets combine. Painting regions overrides this.")
    }

    private func row(_ title: String, _ subtitle: String, on: Bool) -> some View {
        HStack {
            Text("\(title) — \(subtitle)")
            if on { Image(systemName: "checkmark") }
        }
    }

    // MARK: Segments

    private var segments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { idx, group in
                    if idx > 0 {
                        Button { store.toggleGroupOp(group.id) } label: {
                            Text(group.op.rawValue)
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(group.op == .or ? Color.orange.opacity(0.3)
                                                            : Color.secondary.opacity(0.15),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Click to toggle AND/OR")
                    }
                    groupSegment(group)
                }
                ForEach(store.activeExcludes, id: \.self) { tag in
                    chip(tag, role: .excluded)
                }
            }
        }
    }

    private func groupSegment(_ group: VennGroup) -> some View {
        let active = group.id == store.activeGroupID
        return HStack(spacing: 5) {
            if group.sets.isEmpty {
                Text("empty").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(group.sets, id: \.self) { tag in
                chip(tag, role: store.regionRole(tag) ?? .required)
            }
            if store.groups.count > 1 {
                Button { store.removeGroup(group.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this diagram")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(active ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.25)))
        .contentShape(Rectangle())
        .onTapGesture { store.activateGroup(group.id) }
        .help(active ? "Active diagram — new tags land here" : "Click to make active")
    }

    private func chip(_ tag: String, role: RegionRole) -> some View {
        let color: Color
        let symbol: String
        switch role {
        case .required: color = .green; symbol = "plus"
        case .excluded: color = .red; symbol = "minus"
        case .mixed:    color = .gray; symbol = "plusminus"
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(tag).font(.caption)
                .strikethrough(role == .excluded)
            Button { store.clear(tag) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from query")
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
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
