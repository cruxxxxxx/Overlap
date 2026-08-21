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
    @Binding var zoom: CGFloat
    var height: CGFloat = 180

    @GestureState private var pinch: CGFloat = 1
    @State private var hoverMask: Int = 0
    @State private var hovering = false
    private var scale: CGFloat { min(max(zoom * pinch, 1), 5) }

    var body: some View {
        GeometryReader { geo in
            let k = tags.count
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let base = min(geo.size.width, geo.size.height) * 0.27
            let maxTotal = CGFloat(max(1, totals.prefix(k).max() ?? 1))
            let radii: [CGFloat] = (0..<k).map { i in
                base * (0.62 + 0.38 * sqrt(CGFloat(totals[i]) / maxTotal))
            }
            let centers = Self.dataAwareCenters(
                k: k, center: c, r: base, radii: radii, totals: totals, regions: regions)

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

                ForEach(0..<k, id: \.self) { i in
                    let inHover = hoverMask & (1 << i) != 0 && (regions[hoverMask] ?? 0) > 0
                    Circle()
                        .fill(TagPalette.color(for: tags[i]).opacity(0.22))
                        .overlay(Circle().stroke(
                            TagPalette.color(for: tags[i]).opacity(inHover ? 1 : 0.75),
                            lineWidth: inHover ? 2.5 : 1.5))
                        .frame(width: radii[i] * 2, height: radii[i] * 2)
                        .position(centers[i])
                        .blendMode(.multiply)
                        .transition(.scale.combined(with: .opacity))
                }

                // counts (visual; the whole surface is the hit target)
                ForEach(Array(regions.keys.sorted()), id: \.self) { mask in
                    if let cnt = regions[mask], cnt > 0 {
                        let on = selectedRegions.contains(mask)
                        Text("\(cnt)")
                            .font(.caption).bold().monospacedDigit()
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                                          : AnyShapeStyle(.regularMaterial), in: Capsule())
                            .position(Self.regionPoint(mask: mask, centers: centers, radii: radii, global: c, k: k))
                            .allowsHitTesting(false)
                    }
                }
                ForEach(0..<k, id: \.self) { i in
                    Text(tags[i].split(separator: "/").last.map(String.init) ?? tags[i])
                        .font(.caption2).bold()
                        .foregroundStyle(TagPalette.color(for: tags[i]))
                        .position(Self.outLabel(i: i, k: k, center: c, centers: centers, radius: radii[i]))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: k)
            .scaleEffect(scale, anchor: .center)
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
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onEnded { v in
                let mask = maskAt(v.location, centers: centers, radii: radii, c: c, k: k)
                if mask != 0, (regions[mask] ?? 0) > 0 { onToggleRegion(mask) }
            })
            .simultaneousGesture(MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in zoom = min(max(zoom * v, 1), 5) })
            .overlay(alignment: .topTrailing) { zoomControls }
        }
        .frame(height: height)
        .clipped()
    }

    /// Which region (membership mask) sits under a point, inverse-mapped
    /// through the zoom.
    private func maskAt(_ p: CGPoint, centers: [CGPoint], radii: [CGFloat],
                        c: CGPoint, k: Int) -> Int {
        let q = CGPoint(x: (p.x - c.x) / scale + c.x, y: (p.y - c.y) / scale + c.y)
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

    /// Data-aware layout for two sets: nest a subset inside its container,
    /// separate disjoint sets, and scale partial overlaps by the real
    /// intersection. 3+ sets keep the fixed layout (general Euler layouts are
    /// impossible; empty regions there simply show no count pill).
    static func dataAwareCenters(k: Int, center c: CGPoint, r: CGFloat,
                                 radii: [CGFloat], totals: [Int],
                                 regions: [Int: Int]) -> [CGPoint] {
        guard k == 2 else { return centers(k: k, center: c, r: r) }
        let aOnly = regions[0b01] ?? 0
        let bOnly = regions[0b10] ?? 0
        let both = regions[0b11] ?? 0
        let rA = radii[0], rB = radii[1]

        if both == 0 {
            // disjoint: side by side, no overlap
            let gap: CGFloat = 12
            return [CGPoint(x: c.x - rA - gap / 2, y: c.y),
                    CGPoint(x: c.x + rB + gap / 2, y: c.y)]
        }
        if aOnly == 0 && both > 0 {
            // A ⊂ B: nest A inside B, tucked toward one side
            let off = max(0, rB - rA - 6)
            return [CGPoint(x: c.x + off * 0.6, y: c.y), c]
        }
        if bOnly == 0 && both > 0 {
            // B ⊂ A: nest B inside A
            let off = max(0, rA - rB - 6)
            return [c, CGPoint(x: c.x + off * 0.6, y: c.y)]
        }
        // partial overlap: center distance scales with how much they share —
        // f=0 barely touching, f=1 as deep as containment allows
        let f = CGFloat(both) / CGFloat(max(1, min(totals[0], totals[1])))
        let dMax = rA + rB - 8            // barely overlapping
        let dMin = abs(rA - rB) + 10      // deepest sensible overlap
        let d = dMax - sqrt(f) * (dMax - dMin)
        return [CGPoint(x: c.x - d / 2, y: c.y), CGPoint(x: c.x + d / 2, y: c.y)]
    }

    private static func centers(k: Int, center c: CGPoint, r: CGFloat) -> [CGPoint] {
        switch k {
        case 1: return [c]
        case 2: return [CGPoint(x: c.x - r * 0.55, y: c.y), CGPoint(x: c.x + r * 0.55, y: c.y)]
        case 3: return [
            CGPoint(x: c.x, y: c.y - r * 0.55),
            CGPoint(x: c.x - r * 0.6, y: c.y + r * 0.45),
            CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.45),
        ]
        default:
            // 4+: evenly spaced on a ring, all overlapping the center (an
            // Euler-style layout — true Venns don't extend past 3 circles).
            let rr = r * 0.55
            return (0..<k).map { i in
                let a = Double(i) / Double(k) * 2 * .pi - .pi / 2
                return CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr)
            }
        }
    }

    private static func regionPoint(mask: Int, centers: [CGPoint], radii: [CGFloat],
                                    global: CGPoint, k: Int) -> CGPoint {
        let bits = (0..<k).filter { mask & (1 << $0) != 0 }
        if bits.count == 1 {
            let ci = centers[bits[0]]
            let dx = ci.x - global.x, dy = ci.y - global.y
            let len = max(1, sqrt(dx * dx + dy * dy))
            let push = radii[bits[0]] * (k == 1 ? 0 : 0.42)
            return CGPoint(x: ci.x + dx / len * push, y: ci.y + dy / len * push)
        }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for i in bits { sx += centers[i].x; sy += centers[i].y }
        let mid = CGPoint(x: sx / CGFloat(bits.count), y: sy / CGFloat(bits.count))
        let pull: CGFloat = bits.count == k ? 0 : 0.25
        return CGPoint(x: mid.x + (global.x - mid.x) * pull, y: mid.y + (global.y - mid.y) * pull)
    }

    private static func outLabel(i: Int, k: Int, center c: CGPoint, centers: [CGPoint], radius: CGFloat) -> CGPoint {
        let ctr = centers[i]
        let dx = ctr.x - c.x, dy = ctr.y - c.y
        let len = sqrt(dx * dx + dy * dy)
        if k == 1 || len < 4 {
            // centered (single set, or a nested container) — label above
            return CGPoint(x: ctr.x, y: ctr.y - radius - 10)
        }
        return CGPoint(x: ctr.x + dx / len * (radius + 12), y: ctr.y + dy / len * (radius + 12))
    }
}
