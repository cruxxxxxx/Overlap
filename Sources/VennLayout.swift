import Foundation
import CoreGraphics

/// Pure geometry for the Venn diagram — no SwiftUI, so it can be reused by a
/// headless validator (scripts/validate-venn.swift) that reproduces the exact
/// layout offline. `VennView` renders; this decides where everything lands.
enum VennLayout {

    /// Data-driven Euler-ish layout. Every pair gets a target distance from
    /// its REAL overlap — disjoint pairs spread apart, subsets nest, partial
    /// overlaps sink together proportionally — then a deterministic spring
    /// relaxation settles the circles and the result is fitted to the canvas.
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
        // isSubset[i][j]: every item with tag i also has tag j
        var isSubset = [[Bool]](repeating: [Bool](repeating: false, count: k), count: k)
        for i in 0..<k where withTag[i] > 0 {
            for j in 0..<k where j != i {
                isSubset[i][j] = pair[i][j] == withTag[i]
            }
        }
        // a subset's circle must physically fit inside its container
        for i in 0..<k {
            for j in 0..<k where isSubset[i][j] {
                radii[i] = min(radii[i], radii[j] - max(10, radii[j] * 0.2))
            }
        }
        // Disjoint subsets sharing a container must fit side by side inside
        // it: possible only when r_a + r_b ≤ R − gap. Scale them down until
        // the geometry is feasible — then containment and separation can
        // BOTH be satisfied instead of fighting.
        for j in 0..<k {
            let subs = (0..<k).filter { isSubset[$0][j] }
            for a in subs {
                for b in subs where b > a && pair[a][b] == 0 {
                    let maxSum = radii[j] - 8
                    let sum = radii[a] + radii[b]
                    if sum > maxSum {
                        let f = maxSum / sum
                        radii[a] *= f
                        radii[b] *= f
                    }
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
            // ANY shared item means the circles must overlap — the weakest
            // share is still a thin lens (dMax < ri+rj), stronger shares sink
            // toward a near-nest. A gap here would draw sharing pairs as
            // disjoint, which is a lie about the data.
            let dMin = abs(ri - rj) + 10
            let dMax = ri + rj - min(ri, rj) * 0.2
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

        // Hard-constraint pass: springs compromise, geometry may not.
        // Subsets get clamped fully INSIDE their containers (circle-packed),
        // and disjoint pairs may not visually overlap.
        for _ in 0..<80 {
            for i in 0..<k {
                for j in 0..<k where isSubset[i][j] {
                    let dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { d = 0.01 }
                    let maxD = radii[j] - radii[i] - 5
                    if d > maxD {
                        // pull the subset back inside; the container stays put
                        let pull = d - maxD
                        pos[i].x -= dx / d * pull
                        pos[i].y -= dy / d * pull
                    }
                }
            }
            for i in 0..<k {
                for j in (i + 1)..<k where pair[i][j] == 0 {
                    let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { d = 0.01 }
                    let minD = radii[i] + radii[j] + 4
                    if d < minD {
                        let push = (minD - d) / 2
                        pos[i].x -= dx / d * push; pos[i].y -= dy / d * push
                        pos[j].x += dx / d * push; pos[j].y += dy / d * push
                    }
                }
            }
            // Mirror of the disjoint push: a SHARING pair must actually overlap,
            // not merely touch. Springs often leave shared pairs at a tangent
            // under competition; pull them in until there's a real lens. (Subset
            // pairs are handled by the containment passes, so skip them here.)
            for i in 0..<k {
                for j in (i + 1)..<k where pair[i][j] > 0 && !isSubset[i][j] && !isSubset[j][i] {
                    let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { d = 0.01 }
                    let maxD = radii[i] + radii[j] - min(radii[i], radii[j]) * 0.3
                    if d > maxD {
                        let pull = (d - maxD) / 2
                        pos[i].x += dx / d * pull; pos[i].y += dy / d * pull
                        pos[j].x -= dx / d * pull; pos[j].y -= dy / d * pull
                    }
                }
            }
        }
        // Containment gets the FINAL word — the disjoint push above may have
        // nudged a subset back over its container's rim on the last round.
        for _ in 0..<30 {
            for i in 0..<k {
                for j in 0..<k where isSubset[i][j] {
                    let dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { d = 0.01 }
                    let maxD = radii[j] - radii[i] - 5
                    if d > maxD {
                        let pull = d - maxD
                        pos[i].x -= dx / d * pull
                        pos[i].y -= dy / d * pull
                    }
                }
            }
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
    /// outside every out-circle. A region with NO positive-depth point has no
    /// exposed area (Euler impossibility) and can't be painted.
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

    /// Where to place a selected region's badge when it has no exposed area
    /// (no pole): the centroid of its in-circles, nudged toward the smallest
    /// one (the region, if it existed, would live inside that smallest circle).
    static func fallbackAnchor(mask: Int, k: Int, centers: [CGPoint]) -> CGPoint {
        let inBits = (0..<k).filter { mask & (1 << $0) != 0 }
        guard !inBits.isEmpty else { return centers.first ?? .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for i in inBits { x += centers[i].x; y += centers[i].y }
        return CGPoint(x: x / CGFloat(inBits.count), y: y / CGFloat(inBits.count))
    }

    // MARK: - Headless validation

    /// One selected region's rendering verdict.
    struct RegionCheck {
        var mask: Int
        var label: String
        var count: Int
        var paintable: Bool     // has an exposed geometric area (a pole)
        var badge: CGPoint      // where its count badge lands
        var badgeInCircle: Bool // does the badge sit inside any of its in-circles
        var reason: String      // why unpaintable: "" if paintable
    }

    /// Explain why a region has no exposed area: either two of its own sets
    /// don't overlap (a LAYOUT failure, fixable), or the sets all overlap but a
    /// third set's circle covers the lens (a true Euler occlusion for k≥4).
    private static func unpaintableReason(mask: Int, k: Int,
                                          centers: [CGPoint], radii: [CGFloat],
                                          tags: [String]) -> String {
        let inBits = (0..<k).filter { mask & (1 << $0) != 0 }
        let outBits = (0..<k).filter { mask & (1 << $0) == 0 }
        func name(_ i: Int) -> String { tags[i].split(separator: "/").last.map(String.init) ?? tags[i] }
        // 1. any two in-sets that don't overlap?
        var apart: [String] = []
        for a in inBits { for b in inBits where b > a {
            if hypot(centers[a].x - centers[b].x, centers[a].y - centers[b].y) >= radii[a] + radii[b] {
                apart.append("\(name(a))|\(name(b))")
            }
        }}
        if !apart.isEmpty { return "sets apart: " + apart.joined(separator: ", ") }
        // 2. sets overlap — find the deepest point inside every in-circle and
        //    see which out-circles cover it (the occluders).
        guard let smallest = inBits.min(by: { radii[$0] < radii[$1] }) else { return "no sets" }
        let cs = centers[smallest], rs = radii[smallest]
        var bestPt = cs, bestDepth = -CGFloat.greatestFiniteMagnitude
        let steps = 25
        for gy in 0..<steps { for gx in 0..<steps {
            let p = CGPoint(x: cs.x - rs + rs * 2 * CGFloat(gx) / CGFloat(steps - 1),
                            y: cs.y - rs + rs * 2 * CGFloat(gy) / CGFloat(steps - 1))
            var depth = CGFloat.greatestFiniteMagnitude
            for i in inBits { depth = min(depth, radii[i] - hypot(p.x - centers[i].x, p.y - centers[i].y)) }
            if depth > bestDepth { bestDepth = depth; bestPt = p }
        }}
        if bestDepth <= 0 { return "sets barely meet (no common area)" }
        let occluders = outBits.filter { hypot(bestPt.x - centers[$0].x, bestPt.y - centers[$0].y) < radii[$0] }
        return occluders.isEmpty
            ? "unknown"
            : "lens occluded by: " + occluders.map(name).joined(separator: ", ")
    }

    struct Report {
        var selected: Int
        var unpaintable: Int
        var badgesInVoid: Int   // fallback badges that land outside every in-circle
        var checks: [RegionCheck]
    }

    static func regionLabel(_ mask: Int, tags: [String]) -> String {
        let names = tags.enumerated()
            .filter { mask & (1 << $0.offset) != 0 }
            .map { $0.element.split(separator: "/").last.map(String.init) ?? $0.element }
        return names.count == tags.count ? "all" : names.joined(separator: "·")
    }

    /// Reproduce the diagram layout and report, per selected region, whether it
    /// can be painted and where its badge lands — the headless equivalent of
    /// eyeballing the rendered Venn.
    static func validate(tags: [String], totals: [Int], regions: [Int: Int],
                         selected: Set<Int>, canvas: CGSize) -> Report {
        let k = tags.count
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let (centers, radii) = layout(k: k, tags: tags, totals: totals,
                                      regions: regions, canvas: canvas, center: c)
        let poles = regionPoles(k: k, centers: centers, radii: radii, regions: regions)

        var checks: [RegionCheck] = []
        // Mirror the renderer: only count>0 selected regions get a badge; the
        // empty ones (include/exclude powerset residue) draw nothing.
        for mask in selected.sorted() where (regions[mask] ?? 0) > 0 {
            let cnt = regions[mask] ?? 0
            let pole = poles[mask]
            let badge = pole?.point ?? fallbackAnchor(mask: mask, k: k, centers: centers)
            let inBits = (0..<k).filter { mask & (1 << $0) != 0 }
            let inCircle = inBits.contains { i in
                hypot(badge.x - centers[i].x, badge.y - centers[i].y) <= radii[i]
            }
            let reason = pole != nil ? "" :
                unpaintableReason(mask: mask, k: k, centers: centers, radii: radii, tags: tags)
            checks.append(RegionCheck(
                mask: mask, label: regionLabel(mask, tags: tags), count: cnt,
                paintable: pole != nil, badge: badge, badgeInCircle: inCircle, reason: reason))
        }
        return Report(
            selected: checks.count,
            unpaintable: checks.filter { !$0.paintable }.count,
            badgesInVoid: checks.filter { !$0.paintable && !$0.badgeInCircle }.count,
            checks: checks)
    }
}

// MARK: - Dump format (shared by the app dumper and the CLI validator)

/// What the app writes when launched with `OVERLAP_VENN_DUMP=1`: every
/// non-empty diagram's data + current selection, enough to replay the layout.
struct VennDump: Codable {
    struct RegionCount: Codable { var mask: Int; var count: Int }
    struct Diagram: Codable {
        var tags: [String]
        var totals: [Int]
        var regions: [RegionCount]
        var selected: [Int]
    }
    var diagrams: [Diagram]

    var regionMaps: [[Int: Int]] {
        diagrams.map { Dictionary($0.regions.map { ($0.mask, $0.count) }, uniquingKeysWith: { a, _ in a }) }
    }
}
