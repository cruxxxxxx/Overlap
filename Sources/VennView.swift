import SwiftUI

/// The Venn editor. Circles sized by tag totals; the region under the cursor
/// glows, clicking toggles it; painted regions fill with accent. Zoom via
/// pinch or the hover overlay controls.
struct VennView: View {
    let tags: [String]
    let totals: [Int]
    let regions: [Int: Int]            // bitmask -> count
    var selectedRegions: Set<Int> = []
    var onToggleRegion: (Int) -> Void = { _ in }
    var onRemoveTag: (String) -> Void = { _ in }
    var onExcludeTag: (String) -> Void = { _ in }
    @Binding var zoom: CGFloat
    var height: CGFloat = 180

    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var pinch: CGFloat = 1
    @State private var hoverMask: Int = 0
    @State private var hovering = false
    @State private var pan: CGSize = .zero
    @State private var panAtDragStart: CGSize = .zero
    private var scale: CGFloat { min(max(zoom * pinch, 1), 5) }

    var body: some View {
        GeometryReader { geo in
            let k = tags.count
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let (centers, radii) = VennLayout.layout(
                k: k, tags: tags, totals: totals, regions: regions,
                canvas: geo.size, center: c)

            ZStack {
                // fills: painted regions (strong) + hovered region (soft)
                Canvas { ctx, size in
                    func fillRegion(_ mask: Int, _ color: Color) {
                        let inBits = (0..<k).filter { mask & (1 << $0) != 0 }
                        let outBits = (0..<k).filter { mask & (1 << $0) == 0 }
                        ctx.drawLayer { l in
                            for i in inBits { l.clip(to: circlePath(centers[i], radii[i])) }
                            l.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
                            for j in outBits {
                                l.blendMode = .destinationOut
                                l.fill(circlePath(centers[j], radii[j]), with: .color(.black))
                            }
                        }
                    }
                    for mask in selectedRegions where (regions[mask] ?? 0) > 0 {
                        fillRegion(mask, Color.accentColor.opacity(0.45))
                    }
                    if hoverMask != 0, (regions[hoverMask] ?? 0) > 0,
                       !selectedRegions.contains(hoverMask) {
                        fillRegion(hoverMask, Color.accentColor.opacity(0.16))
                    }
                }
                .allowsHitTesting(false)

                // Monochrome circles: overlaps stack into brighter (dark mode)
                // or darker (light mode) shades, so region depth reads as
                // luminance — and the accent selection is the ONLY color.
                let dark = colorScheme == .dark
                let ink = dark ? Color.white : Color.black
                ForEach(0..<k, id: \.self) { i in
                    let inHover = hoverMask & (1 << i) != 0 && (regions[hoverMask] ?? 0) > 0
                    Circle()
                        .fill(ink.opacity(dark ? 0.10 : 0.06))
                        .overlay(Circle().stroke(
                            inHover ? Color.accentColor : ink.opacity(0.45),
                            lineWidth: inHover ? 2.5 : 1.2))
                        .frame(width: radii[i] * 2, height: radii[i] * 2)
                        .contentShape(Circle())
                        .contextMenu {
                            Text(tags[i])
                            Divider()
                            Button("Remove from Diagram") { onRemoveTag(tags[i]) }
                            Button("Exclude (NOT)") { onExcludeTag(tags[i]) }
                        }
                        .position(centers[i])
                        .blendMode(dark ? .screen : .multiply)
                        .transition(.scale.combined(with: .opacity))
                }

                // count appears only for the region under the cursor
                // (the full list lives in the chips row)
                // Selected regions ALWAYS get a badge (a selected intersection
                // often has no paintable geometric area — Euler impossibility —
                // so the fill alone can't confirm it's on); hovered region also
                // gets one. Pole if the area is exposed, else a fallback anchor
                // from the in-circle centers so the marker still lands sensibly.
                let poles = VennLayout.regionPoles(k: k, centers: centers, radii: radii, regions: regions)
                ForEach(Array(regions.keys.sorted()), id: \.self) { mask in
                    let on = selectedRegions.contains(mask)
                    if let cnt = regions[mask], cnt > 0, mask == hoverMask || on {
                        let anchor = poles[mask]?.point
                            ?? VennLayout.fallbackAnchor(mask: mask, k: k, centers: centers)
                        Text("\(cnt)")
                            .font(.caption).bold().monospacedDigit()
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                                          : AnyShapeStyle(.regularMaterial), in: Capsule())
                            .overlay(Capsule().stroke(Color.accentColor,
                                                      lineWidth: on && poles[mask] == nil ? 1.5 : 0))
                            .position(anchor)
                            .allowsHitTesting(false)
                    }
                }
                // set labels, inside their own circle, pushed away from
                // neighbors. Clicking a label toggles that set's EXCLUSIVE
                // region — the escape hatch when the only-this-set area is
                // buried under other circles and can't be clicked directly.
                ForEach(0..<k, id: \.self) { i in
                    let soloMask = 1 << i
                    let solo = regions[soloMask] ?? 0
                    let inHover = hoverMask & soloMask != 0 && (regions[hoverMask] ?? 0) > 0
                    let soloOn = selectedRegions.contains(soloMask)
                    Text(tags[i].split(separator: "/").last.map(String.init) ?? tags[i])
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(soloOn ? Color.accentColor
                                        : inHover ? Color.accentColor : Color.primary.opacity(0.8))
                        .underline(soloOn)
                        .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .white.opacity(0.6),
                                radius: 2)
                        .position(VennLayout.labelAnchor(i: i, k: k, centers: centers, radii: radii))
                        .onTapGesture {
                            if solo > 0 { onToggleRegion(soloMask) }
                        }
                        .help(solo > 0
                              ? "Click: only \(tags[i]) (\(solo)) — the exclusive region"
                              : "No images carry only \(tags[i]) in this diagram")
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: k)
            .scaleEffect(scale, anchor: .center)
            .offset(pan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovering = true
                    hoverMask = resolveMask(maskAt(p, centers: centers, radii: radii, c: c, k: k))
                case .ended:
                    hovering = false
                    hoverMask = 0
                }
            }
            // One gesture, two meanings: a still click toggles the region
            // under the cursor; a real drag pans the zoomed diagram.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    guard scale > 1.01 else { return }
                    pan = CGSize(width: panAtDragStart.width + v.translation.width,
                                 height: panAtDragStart.height + v.translation.height)
                }
                .onEnded { v in
                    let moved = hypot(v.translation.width, v.translation.height)
                    panAtDragStart = pan
                    guard moved < 4 else { return }   // it was a pan, not a click
                    let mask = resolveMask(maskAt(v.location, centers: centers, radii: radii, c: c, k: k))
                    if mask != 0, (regions[mask] ?? 0) > 0 { onToggleRegion(mask) }
                })
            .simultaneousGesture(MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in zoom = min(max(zoom * v, 1), 5) })
            .onChange(of: zoom) { z in
                if z <= 1.01 { pan = .zero; panAtDragStart = .zero }
            }
            .overlay(alignment: .topTrailing) { zoomControls }
        }
        .frame(height: height)
        .clipped()
    }

    /// Layout can't always give every real intersection its own exposed
    /// area (Euler impossibility). When the exact region under the cursor is
    /// empty, fall through to the most specific NON-EMPTY sub-intersection —
    /// so clicking a phantom triple-overlap selects the real pair inside it.
    private func resolveMask(_ raw: Int) -> Int {
        guard raw != 0 else { return 0 }
        if (regions[raw] ?? 0) > 0 { return raw }
        var best = 0, bestBits = 0, bestCnt = 0
        for (m, cnt) in regions where cnt > 0 && (m & raw) == m {
            let bits = m.nonzeroBitCount
            if bits > bestBits || (bits == bestBits && cnt > bestCnt) {
                best = m; bestBits = bits; bestCnt = cnt
            }
        }
        return best
    }

    /// Which region (membership mask) sits under a point, inverse-mapped
    /// through the zoom and pan.
    private func maskAt(_ p: CGPoint, centers: [CGPoint], radii: [CGFloat],
                        c: CGPoint, k: Int) -> Int {
        let q = CGPoint(x: (p.x - pan.width - c.x) / scale + c.x,
                        y: (p.y - pan.height - c.y) / scale + c.y)
        var mask = 0
        for i in 0..<k where hypot(q.x - centers[i].x, q.y - centers[i].y) <= radii[i] {
            mask |= (1 << i)
        }
        return mask
    }

    @ViewBuilder private var zoomControls: some View {
        if hovering || zoom > 1.01 {
            HStack(spacing: 6) {
                Button { zoom = max(1, zoom - 0.75) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = min(5, zoom + 0.75) } label: { Image(systemName: "plus.magnifyingglass") }
                if zoom > 1.01 {
                    Button { zoom = 1 } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.regularMaterial, in: Capsule())
            .padding(6)
            .transition(.opacity)
        }
    }

    private func circlePath(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}
