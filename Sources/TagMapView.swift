import SwiftUI

/// The "recursive Venn" tag navigator: zoomable circle packing. The current
/// level's nodes are packed circles; a node's children are packed *inside* it
/// as a preview. Click a category to zoom in, a leaf to add it to the Venn.
/// Static layout — no physics, no drift.
struct TagMapView: View {
    let nodes: [TagNode]
    var emptyMessage = "Nothing here"
    var onDrill: (String) -> Void
    var onLeaf: (String) -> Void

    @State private var hoverID: String?

    private struct Layout {
        var top: [CirclePack.Placed]
        var byID: [String: TagNode]
        var scale: CGFloat
        var offset: CGPoint
    }

    private func layout(in size: CGSize) -> Layout {
        let maxCount = max(1, nodes.map { $0.count }.max() ?? 1)
        let items = nodes.map { node in
            CirclePack.Item(id: node.fullPath,
                            r: 18 + 42 * sqrt(CGFloat(node.count) / CGFloat(maxCount)))
        }
        let placed = CirclePack.pack(items)
        let bound = CirclePack.boundingRadius(placed)
        let fit = min(size.width, size.height) * 0.47 / max(bound, 1)
        return Layout(
            top: placed,
            byID: Dictionary(uniqueKeysWithValues: nodes.map { ($0.fullPath, $0) }),
            scale: min(fit, 2.2),
            offset: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    var body: some View {
        GeometryReader { geo in
            let l = layout(in: geo.size)
            ZStack {
                ForEach(l.top, id: \.id) { p in
                    if let node = l.byID[p.id] {
                        nodeCircle(node, placed: p, layout: l)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if nodes.isEmpty {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.75),
                       value: nodes.map(\.fullPath))
        }
    }

    private func nodeCircle(_ node: TagNode, placed: CirclePack.Placed, layout l: Layout) -> some View {
        let r = placed.r * l.scale
        let pos = CGPoint(x: l.offset.x + placed.x * l.scale,
                          y: l.offset.y + placed.y * l.scale)
        let color = TagPalette.color(for: node.fullPath)
        let hovered = hoverID == node.fullPath
        let hasKids = !node.children.isEmpty

        return ZStack {
            Circle()
                .fill(color.opacity(hasKids ? 0.14 : 0.55))
                .overlay(Circle().stroke(color.opacity(hovered ? 1 : 0.65),
                                         lineWidth: hovered ? 2.5 : 1.5))
                .shadow(color: color.opacity(hovered ? 0.45 : 0.2), radius: hovered ? 8 : 4, y: 2)

            if hasKids {
                childPreview(node, radius: r)
                // category label pinned to the top arc
                VStack {
                    Text(node.name)
                        .font(.system(size: max(9, min(15, r * 0.17)), weight: .bold))
                        .foregroundStyle(color)
                        .padding(.top, r * 0.06)
                    Spacer()
                }
            } else {
                VStack(spacing: 1) {
                    Text(node.name)
                        .font(.system(size: max(9, r * 0.28), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: r * 1.6)
                    if r > 26 {
                        Text("\(node.count)")
                            .font(.system(size: max(8, r * 0.2)))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .shadow(radius: 1)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .contentShape(Circle())
        .scaleEffect(hovered ? 1.04 : 1)   // BEFORE .position: scale about the circle's own center
        .onHover { hoverID = $0 ? node.fullPath : (hoverID == node.fullPath ? nil : hoverID) }
        .onTapGesture {
            if hasKids { onDrill(node.name) } else { onLeaf(node.fullPath) }
        }
        .help(hasKids ? "\(node.name) — \(node.count) files, click to zoom in"
                      : "\(node.fullPath) — \(node.count) files, click to add to the diagram")
        .position(pos)
    }

    /// The node's children packed inside it — the nested "recursive" level.
    private func childPreview(_ node: TagNode, radius r: CGFloat) -> some View {
        let kids = node.children
        let maxCount = max(1, kids.map { $0.count }.max() ?? 1)
        let items = kids.map { kid in
            CirclePack.Item(id: kid.fullPath,
                            r: 6 + 16 * sqrt(CGFloat(kid.count) / CGFloat(maxCount)))
        }
        let placed = CirclePack.pack(items)
        let bound = CirclePack.boundingRadius(placed)
        let fit = (r * 0.72) / max(bound, 1)
        let byID = Dictionary(uniqueKeysWithValues: kids.map { ($0.fullPath, $0) })

        return ZStack {
            ForEach(placed, id: \.id) { p in
                if let kid = byID[p.id] {
                    let kr = p.r * fit
                    ZStack {
                        Circle()
                            .fill(TagPalette.color(for: kid.fullPath).opacity(0.5))
                            .overlay(Circle().stroke(TagPalette.color(for: kid.fullPath).opacity(0.5), lineWidth: 1))
                        if kr > 13 {
                            Text(kid.name)
                                .font(.system(size: max(6, kr * 0.32), weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.4)
                                .frame(width: kr * 1.7)
                                .shadow(radius: 1)
                        }
                    }
                    .frame(width: kr * 2, height: kr * 2)
                    .offset(x: p.x * fit, y: p.y * fit + r * 0.08)
                }
            }
        }
        .allowsHitTesting(false)   // taps go to the parent circle
    }
}
