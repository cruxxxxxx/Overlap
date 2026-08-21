import Foundation
import CoreGraphics

/// Greedy circle-packing layout: place circles (sorted large→small) tangent to
/// already-placed pairs, choosing the valid spot closest to the centroid.
/// Deterministic, no physics. Positions come back centered on the origin.
enum CirclePack {

    struct Item {
        let id: String
        let r: CGFloat
    }

    struct Placed {
        let id: String
        var x: CGFloat
        var y: CGFloat
        let r: CGFloat
    }

    static let pad: CGFloat = 2

    static func pack(_ items: [Item]) -> [Placed] {
        let sorted = items.sorted { $0.r > $1.r }
        var placed: [Placed] = []
        for it in sorted {
            switch placed.count {
            case 0:
                placed.append(Placed(id: it.id, x: 0, y: 0, r: it.r))
            case 1:
                let p = placed[0]
                placed.append(Placed(id: it.id, x: p.x + p.r + it.r + pad, y: p.y, r: it.r))
            default:
                placed.append(place(it, among: placed))
            }
        }
        return recenter(placed)
    }

    private static func place(_ it: Item, among placed: [Placed]) -> Placed {
        var best: CGPoint?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                for cand in tangentPositions(placed[i], placed[j], r: it.r) {
                    guard !collides(cand, it.r, placed) else { continue }
                    let d = hypot(cand.x, cand.y)
                    if d < bestDist { best = cand; bestDist = d }
                }
            }
        }
        if best == nil {
            // fallback: spiral outward until a free spot appears
            var angle: CGFloat = 0
            var dist: CGFloat = it.r
            while best == nil {
                let cand = CGPoint(x: cos(angle) * dist, y: sin(angle) * dist)
                if !collides(cand, it.r, placed) { best = cand }
                angle += 0.45
                dist += it.r * 0.06
            }
        }
        return Placed(id: it.id, x: best!.x, y: best!.y, r: it.r)
    }

    /// The two positions where a circle of radius r is tangent to both a and b.
    private static func tangentPositions(_ a: Placed, _ b: Placed, r: CGFloat) -> [CGPoint] {
        let ra = a.r + r + pad
        let rb = b.r + r + pad
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > 0.001, d < ra + rb, d > abs(ra - rb) else { return [] }
        let base = (ra * ra - rb * rb + d * d) / (2 * d)
        let h2 = ra * ra - base * base
        guard h2 >= 0 else { return [] }
        let h = sqrt(h2)
        let px = a.x + base * dx / d
        let py = a.y + base * dy / d
        return [
            CGPoint(x: px + h * dy / d, y: py - h * dx / d),
            CGPoint(x: px - h * dy / d, y: py + h * dx / d),
        ]
    }

    private static func collides(_ p: CGPoint, _ r: CGFloat, _ placed: [Placed]) -> Bool {
        placed.contains { hypot(p.x - $0.x, p.y - $0.y) < r + $0.r + pad - 0.5 }
    }

    /// Shift so the weighted centroid sits at the origin.
    private static func recenter(_ placed: [Placed]) -> [Placed] {
        guard !placed.isEmpty else { return placed }
        var cx: CGFloat = 0, cy: CGFloat = 0, w: CGFloat = 0
        for p in placed { cx += p.x * p.r; cy += p.y * p.r; w += p.r }
        cx /= w; cy /= w
        return placed.map { Placed(id: $0.id, x: $0.x - cx, y: $0.y - cy, r: $0.r) }
    }

    /// Radius of the smallest origin-centered circle containing the layout.
    static func boundingRadius(_ placed: [Placed]) -> CGFloat {
        placed.map { hypot($0.x, $0.y) + $0.r }.max() ?? 1
    }
}
