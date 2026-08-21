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
            let (centers, radii) = Self.layout(
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

                // counts are on-demand: only the hovered region and painted
                // regions show their number (full list lives in the chips row)
                let poles = Self.regionPoles(k: k, centers: centers, radii: radii, regions: regions)
                ForEach(Array(regions.keys.sorted()), id: \.self) { mask in
                    if let cnt = regions[mask], cnt > 0,
                       let pole = poles[mask],
                       selectedRegions.contains(mask) || mask == hoverMask {
                        let on = selectedRegions.contains(mask)
                        Text("\(cnt)")
                            .font(.caption).bold().monospacedDigit()
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                                          : AnyShapeStyle(.regularMaterial), in: Capsule())
                            .position(pole.point)
                            .allowsHitTesting(false)
                    }
                }
                // set labels, inside their own circle, pushed away from neighbors
                ForEach(0..<k, id: \.self) { i in
                    let inHover = hoverMask & (1 << i) != 0 && (regions[hoverMask] ?? 0) > 0
                    Text(tags[i].split(separator: "/").last.map(String.init) ?? tags[i])
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(inHover ? Color.accentColor : Color.primary.opacity(0.8))
                        .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .white.opacity(0.6),
                                radius: 2)
                        .position(Self.labelAnchor(i: i, k: k, centers: centers, radii: radii))
                        .allowsHitTesting(false)
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
                    hoverMask = maskAt(p, centers: centers, radii: radii, c: c, k: k)
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
                    let mask = maskAt(v.location, centers: centers, radii: radii, c: c, k: k)
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

    /// Data-driven Euler-ish layout. Every pair gets a target distance from
    /// its REAL overlap — disjoint pairs spread apart, subsets nest, partial
    /// overlaps sink together proportionally — then a deterministic spring
    /// relaxation settles the circles and the result is fitted to the canvas.
    /// Circles stay circles; the geometry just tells the truth about the data.
    static func layout(k: Int, tags: [String], totals: [Int], regions: [Int: Int],
                       canvas: CGSize, center c: CGPoint) -> ([CGPoint], [CGFloat]) {
        let base = min(canvas.width, canvas.height) * 0.27
        let maxTotal = CGFloat(max(1, totals.prefix(k).max() ?? 1))
        var radii: [CGFloat] = (0..<k).map { i in
            base * (0.5 + 0.5 * sqrt(CGFloat(totals[i]) / maxTotal))
        }
        guard k > 1 else { return ([c], radii) }

        // pairwise shared counts + subset detection from the region data
        var pair = [[Int]](repeating: [Int](repeating: 0, count: k), count: k)
        var withTag = [Int](repeating: 0, count: k)
        for (mask, cnt) in regions {
            for i in 0..<k where mask & (1 << i) != 0 {
                withTag[i] += cnt
                for j in (i + 1)..<k where mask & (1 << j) != 0 {
                    pair[i][j] += cnt; pair[j][i] += cnt
                }
            }
        }

        func targetDistance(_ i: Int, _ j: Int) -> CGFloat {
            let shared = pair[i][j]
            let ri = radii[i], rj = radii[j]
            if shared == 0 { return ri + rj + base * 0.9 }           // disjoint: real air
            if shared == withTag[i] || shared == withTag[j] {        // subset: nest
                return abs(ri - rj) * 0.5
            }
            let f = CGFloat(shared) / CGFloat(max(1, min(withTag[i], withTag[j])))
            // weak overlaps stay shallow — only meaningful shares sink deep
            let dMax = ri + rj + base * 0.15
            let dMin = abs(ri - rj) + 10
            return dMax - pow(f, 0.4) * (dMax - dMin)
        }

        // deterministic ring start, then spring relaxation toward targets
        var pos: [CGPoint] = (0..<k).map { i in
            let a = Double(i) / Double(k) * 2 * .pi - .pi / 2
            return CGPoint(x: c.x + CGFloat(cos(a)) * base * 0.6,
                           y: c.y + CGFloat(sin(a)) * base * 0.6)
        }
        var step: CGFloat = 0.25
        for _ in 0..<220 {
            for i in 0..<k {
                for j in (i + 1)..<k {
                    let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { d = 0.01 }
                    let err = (d - targetDistance(i, j)) * step / 2
                    let ux = dx / d, uy = dy / d
                    pos[i].x += ux * err; pos[i].y += uy * err
                    pos[j].x -= ux * err; pos[j].y -= uy * err
                }
            }
            step *= 0.985
        }

        // fit the settled layout into the canvas (scale positions AND radii)
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for i in 0..<k {
            minX = min(minX, pos[i].x - radii[i]); maxX = max(maxX, pos[i].x + radii[i])
            minY = min(minY, pos[i].y - radii[i]); maxY = max(maxY, pos[i].y + radii[i])
        }
        let pad: CGFloat = 26   // room for outside labels
        let scale = min(2.4, min((canvas.width - pad * 2) / max(maxX - minX, 1),
                                 (canvas.height - pad * 2) / max(maxY - minY, 1)))
        let mid = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let centers = pos.map { p in
            CGPoint(x: c.x + (p.x - mid.x) * scale, y: c.y + (p.y - mid.y) * scale)
        }
        radii = radii.map { $0 * scale }
        return (centers, radii)
    }

    /// For every non-empty region, the deepest interior point ("pole") — the
    /// spot farthest from all boundaries while inside every in-circle and
    /// outside every out-circle. Found by grid sampling; exact enough for
    /// labels and cheap (a few thousand distance checks).
    static func regionPoles(k: Int, centers: [CGPoint], radii: [CGFloat],
                            regions: [Int: Int]) -> [Int: (point: CGPoint, depth: CGFloat)] {
        var out: [Int: (point: CGPoint, depth: CGFloat)] = [:]
        for (mask, cnt) in regions where cnt > 0 {
            let inBits = (0..<k).filter { mask & (1 << $0) != 0 }
            let outBits = (0..<k).filter { mask & (1 << $0) == 0 }
            guard let smallest = inBits.min(by: { radii[$0] < radii[$1] }) else { continue }

            // the region must live inside its smallest in-circle — sample there
            let cs = centers[smallest], rs = radii[smallest]
            var best: (point: CGPoint, depth: CGFloat)?
            let steps = 17
            for gy in 0..<steps {
                for gx in 0..<steps {
                    let p = CGPoint(
                        x: cs.x - rs + rs * 2 * CGFloat(gx) / CGFloat(steps - 1),
                        y: cs.y - rs + rs * 2 * CGFloat(gy) / CGFloat(steps - 1))
                    // depth = distance to the nearest constraint boundary
                    var depth = CGFloat.greatestFiniteMagnitude
                    for i in inBits {
                        depth = min(depth, radii[i] - hypot(p.x - centers[i].x, p.y - centers[i].y))
                    }
                    for j in outBits {
                        depth = min(depth, hypot(p.x - centers[j].x, p.y - centers[j].y) - radii[j])
                    }
                    if depth > (best?.depth ?? 0) { best = (p, depth) }
                }
            }
            if let best, best.depth > 0 { out[mask] = best }
        }
        return out
    }

    /// A set's label sits inside its own circle, pushed away from the crowd
    /// of neighboring circles so it clearly belongs to its ring.
    static func labelAnchor(i: Int, k: Int, centers: [CGPoint], radii: [CGFloat]) -> CGPoint {
        let ci = centers[i]
        guard k > 1 else { return CGPoint(x: ci.x, y: ci.y - radii[i] * 0.55) }
        var ax: CGFloat = 0, ay: CGFloat = 0
        for j in 0..<k where j != i { ax += centers[j].x; ay += centers[j].y }
        ax /= CGFloat(k - 1); ay /= CGFloat(k - 1)
        var dx = ci.x - ax, dy = ci.y - ay
        let len = sqrt(dx * dx + dy * dy)
        if len < 1 { dx = 0; dy = -1 } else { dx /= len; dy /= len }
        // just inside the rim, on the side facing away from the neighbors
        return CGPoint(x: ci.x + dx * radii[i] * 0.72, y: ci.y + dy * radii[i] * 0.72)
    }
}
