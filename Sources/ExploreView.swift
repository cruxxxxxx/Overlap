import SwiftUI

/// The Explore sidebar. The blob navigator respects the tag hierarchy: at root
/// it shows top-level categories (cat, type, auth…), drill a category to its
/// tags, tap a tag to add it as a Venn set. Everything shown is filtered to
/// what co-occurs (non-zero) with the current selection. The Venn header lets
/// you click regions to isolate overlaps; the grid on the right follows.
struct ExploreView: View {
    @EnvironmentObject var store: TagStore
    @State private var browse: [String] = []   // drill path within the co-occur tree
    @State private var vennZoom: CGFloat = 1
    @State private var vennHeight: CGFloat = 190
    @State private var heightAtDragStart: CGFloat = 190

    private var chain: [String] { store.querySets }

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
            if !chain.isEmpty {
                let d = store.vennData(chain)
                VennView(tags: chain, totals: d.totals, regions: d.regions,
                         selectedRegions: store.selectedRegions,
                         onToggleRegion: { store.toggleRegion($0) },
                         zoom: $vennZoom, height: vennHeight)
                regionChips(d.regions)
                resizeHandle
                Divider()
            }
            browseHeader
            Divider()
            TagMapView(
                nodes: currentLevel,
                onDrill: { browse.append($0) },
                onLeaf: { store.include($0) })
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onChange(of: chain) { _ in browse = [] }   // reset drill when the Venn changes
    }

    /// Every non-empty region as a toggle chip — guarantees access to overlaps
    /// that are geometrically unreachable in the diagram.
    private func regionChips(_ regions: [Int: Int]) -> some View {
        let sorted = regions.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }.prefix(40)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if !store.selectedRegions.isEmpty {
                    Button { store.clearRegions() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear painted regions")
                }
                ForEach(Array(sorted), id: \.key) { mask, cnt in
                    let on = store.selectedRegions.contains(mask)
                    Button { store.toggleRegion(mask) } label: {
                        HStack(spacing: 3) {
                            Text(regionLabel(mask)).lineLimit(1)
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
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
    }

    private func regionLabel(_ mask: Int) -> String {
        let names = chain.enumerated()
            .filter { mask & (1 << $0.offset) != 0 }
            .map { $0.element.split(separator: "/").last.map(String.init) ?? $0.element }
        return names.count == chain.count ? "all" : names.joined(separator: "·")
    }

    private var resizeHandle: some View {
        Capsule().fill(Color.secondary.opacity(0.4))
            .frame(width: 44, height: 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(Color.secondary.opacity(0.06))
            .gesture(DragGesture()
                .onChanged { v in
                    vennHeight = min(max(heightAtDragStart + v.translation.height, 120), 700)
                }
                .onEnded { _ in heightAtDragStart = vennHeight })
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }

    // MARK: Headers

    private var browseHeader: some View {
        HStack(spacing: 6) {
            Button { store.clearQuery(); browse = [] } label: {
                Image(systemName: "house.fill").font(.caption)
            }
            .buttonStyle(.plain).help("Clear the query")
            .disabled(chain.isEmpty && browse.isEmpty)
            if !chain.isEmpty {
                Button { store.popSet() } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.caption)
                }
                .buttonStyle(.plain).help("Remove last Venn set")
            }
            if !browse.isEmpty {
                Button { browse.removeLast() } label: {
                    Label(browse.joined(separator: "/"), systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain).help("Back up the category drill")
            } else {
                Text(chain.isEmpty ? "Categories" : "Add to diagram")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.results.count) imgs").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

}
