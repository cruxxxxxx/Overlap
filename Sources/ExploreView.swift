import SwiftUI

/// The Explore sidebar: one or more Venn diagrams (ANDed together) on top,
/// the circle-pack tag map below. Tap a leaf in the map to add it to the
/// active diagram; click a diagram to activate it; paint regions to shape
/// each diagram's logic. All of it edits the one query the QueryBar shows.
struct ExploreView: View {
    @EnvironmentObject var store: TagStore
    @State private var browse: [String] = []   // drill path within the co-occur tree
    @State private var vennZoom: [UUID: CGFloat] = [:]
    @State private var vennHeight: CGFloat = 190
    @State private var heightAtDragStart: CGFloat = 190

    private var allSets: [String] { store.querySets }

    // Tree of what co-occurs with the current selection (non-zero only).
    private var coTree: [TagNode] {
        let pairs = store.coOccurring().map { ($0.tag, $0.count) }
        let dict = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        return TagNode.buildTree(from: dict)
    }

    private func level(_ path: [String]) -> [TagNode] {
        var nodes = coTree
        for seg in path {
            guard let n = nodes.first(where: { $0.name == seg }) else { return [] }
            nodes = n.children
        }
        return nodes
    }

    private var currentLevel: [TagNode] { level(browse) }

    var body: some View {
        VStack(spacing: 0) {
            if store.groups.contains(where: { !$0.sets.isEmpty }) || store.groups.count > 1 {
                diagramStack
                Divider()
            }
            browseHeader
            Divider()
            TagMapView(
                nodes: currentLevel,
                emptyMessage: allSets.isEmpty
                    ? "Nothing here"
                    : "No other tags co-occur with the current results — any circle added now would match 0 images.\nTry Any mode or paint a wider region on a diagram above.",
                onDrill: { browse.append($0) },
                onLeaf: { store.include($0) })
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onChange(of: allSets) { _ in browse = [] }   // reset drill when the query changes
    }

    // MARK: Diagram stack

    private var diagramStack: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { idx, group in
                    diagramCard(group, index: idx)
                }
                Button {
                    store.addGroup()
                } label: {
                    Label("Add diagram", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .help("A new diagram ANDs with the others")
            }
        }
        .frame(maxHeight: vennHeight * CGFloat(min(store.groups.count, 2)) + 60)
        .overlay(alignment: .bottom) { resizeHandle }
    }

    private func diagramCard(_ group: VennGroup, index: Int) -> some View {
        let active = group.id == store.activeGroupID
        let d = store.vennData(group.sets)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text("Diagram \(index + 1)")
                    .font(.caption).fontWeight(active ? .semibold : .regular)
                if index > 0 {
                    Button { store.toggleGroupOp(group.id) } label: {
                        Text(group.op.rawValue)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(group.op == .or ? Color.orange.opacity(0.3)
                                                        : Color.secondary.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Click to toggle AND/OR with the previous diagram")
                }
                Spacer()
                if !group.regions.isEmpty {
                    Button { store.clearRegions(group: group.id) } label: {
                        Image(systemName: "paintbrush").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear painted regions")
                }
                if store.groups.count > 1 {
                    Button { store.removeGroup(group.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Remove this diagram")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            if group.sets.isEmpty {
                Text("Tap tags below to add circles")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                VennView(tags: group.sets, totals: d.totals, regions: d.regions,
                         selectedRegions: group.regions,
                         onToggleRegion: { store.toggleRegion(group: group.id, mask: $0) },
                         zoom: zoomBinding(group.id),
                         height: vennHeight)
                regionChips(group, regions: d.regions)
            }
        }
        .background(active ? Color.accentColor.opacity(0.05) : .clear)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(active ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15)))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { store.activateGroup(group.id) })
    }

    private func zoomBinding(_ id: UUID) -> Binding<CGFloat> {
        Binding(get: { vennZoom[id] ?? 1 }, set: { vennZoom[id] = $0 })
    }

    /// Every non-empty region as a toggle chip — guarantees access to overlaps
    /// that are geometrically unreachable in the diagram.
    private func regionChips(_ group: VennGroup, regions: [Int: Int]) -> some View {
        let sorted = regions.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }.prefix(40)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(sorted), id: \.key) { mask, cnt in
                    let on = group.regions.contains(mask)
                    Button { store.toggleRegion(group: group.id, mask: mask) } label: {
                        HStack(spacing: 3) {
                            Text(regionLabel(mask, sets: group.sets)).lineLimit(1)
                            Text("\(cnt)").opacity(0.7)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(on ? AnyShapeStyle(Color.accentColor)
                                      : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 5)
        }
    }

    private func regionLabel(_ mask: Int, sets: [String]) -> String {
        let names = sets.enumerated()
            .filter { mask & (1 << $0.offset) != 0 }
            .map { $0.element.split(separator: "/").last.map(String.init) ?? $0.element }
        return names.count == sets.count ? "all" : names.joined(separator: "·")
    }

    private var resizeHandle: some View {
        Capsule().fill(Color.secondary.opacity(0.4))
            .frame(width: 44, height: 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { v in
                    vennHeight = min(max(heightAtDragStart + v.translation.height, 120), 700)
                }
                .onEnded { _ in heightAtDragStart = vennHeight })
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }

    // MARK: Browse header

    private var browseHeader: some View {
        HStack(spacing: 6) {
            Button { store.clearQuery(); browse = [] } label: {
                Image(systemName: "house.fill").font(.caption)
            }
            .buttonStyle(.plain).help("Clear the query")
            .disabled(allSets.isEmpty && browse.isEmpty)
            if !store.activeGroup.sets.isEmpty {
                Button { store.popSet() } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.caption)
                }
                .buttonStyle(.plain).help("Remove the active diagram's last circle")
            }
            if !browse.isEmpty {
                Button { browse.removeLast() } label: {
                    Label(browse.joined(separator: "/"), systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain).help("Back up the category drill")
            } else {
                Text(allSets.isEmpty ? "Categories" : "Add to Diagram \(store.activeGroupIndex + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.results.count) imgs").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}
