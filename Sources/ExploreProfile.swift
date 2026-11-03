import Foundation
import Accelerate

/// The on-device taste profile behind the Explore page: several EMA centroids,
/// so distinct interests stay distinct instead of averaging into mush.
///
/// The profile is a pure fold over a short log of events. Nothing else is
/// stored, so unliking, forgetting a taste, or a file becoming hidden just
/// removes events and refolds: no trace of that image's embedding survives.
/// Thresholds come from real MobileCLIP-S2 vectors: random pairs have a median
/// cosine of 0.25 and a p99 of 0.58; nearest neighbors a median of 0.66.
enum TasteSignal: String, Codable {
    case like, opened, viewed, lessLikeThis

    var strength: Float {
        switch self {
        case .like, .lessLikeThis:
            return 1
        case .opened:
            return 0.4
        case .viewed:
            return 0.2
        }
    }

    /// A glance can refine an existing taste but isn't enough to start one.
    var canStartTaste: Bool { self != .viewed }
}

struct TasteEvent: Codable, Identifiable {
    var id = UUID()
    let path: String
    let signal: TasteSignal
    let date: Date
    let vector: Data   // little-endian Float32, normalized
}

struct TasteCentroid: Identifiable {
    let id: UUID         // the event that started it, stable across refolds
    var vector: [Float]
    var weight: Float    // decayed sum of signal strengths: how much this taste counts
    var mass: Float      // undecayed sum: sets how fast the EMA still moves
    var lastDate: Date
    var eventIDs: Set<UUID>
    var exemplar: String // the latest liked image, else the latest opened
    var exemplarIsLike: Bool
}

struct TasteProfile {
    static let maxTastes = 6
    static let maxAvoids = 3
    static let joinCosine: Float = 0.55
    static let minimumAlpha: Float = 0.12
    static let halfLifeDays: Double = 45

    var tastes: [TasteCentroid] = []
    var avoids: [TasteCentroid] = []

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return -1
        }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Replay `events` (oldest first) into a profile as of `now`.
    static func fold(_ events: [TasteEvent], now: Date = Date()) -> TasteProfile {
        var profile = TasteProfile()
        for event in events {
            let vector = Self.vector(event.vector)
            if event.signal == .lessLikeThis {
                absorb(event, vector, into: &profile.avoids, limit: maxAvoids)
            } else {
                absorb(event, vector, into: &profile.tastes, limit: maxTastes)
            }
        }
        for i in profile.tastes.indices {
            decay(&profile.tastes[i], to: now)
        }
        profile.tastes.sort { $0.weight > $1.weight }
        return profile
    }

    private static func absorb(_ event: TasteEvent, _ vector: [Float],
                               into centroids: inout [TasteCentroid], limit: Int) {
        let nearest = centroids.indices.max {
            cosine(centroids[$0].vector, vector) < cosine(centroids[$1].vector, vector)
        }
        if let nearest, cosine(centroids[nearest].vector, vector) >= joinCosine {
            update(&centroids[nearest], with: event, vector)
            return
        }
        guard event.signal.canStartTaste else {
            return
        }
        centroids.append(TasteCentroid(id: event.id, vector: vector, weight: event.signal.strength,
                                       mass: event.signal.strength, lastDate: event.date,
                                       eventIDs: [event.id], exemplar: event.path,
                                       exemplarIsLike: event.signal == .like))
        if centroids.count > limit {
            mergeClosestPair(&centroids)
        }
    }

    /// EMA step. Early on alpha follows a running mean, so a new taste settles
    /// quickly; once it has mass, alpha bottoms out and it can still drift.
    private static func update(_ centroid: inout TasteCentroid, with event: TasteEvent, _ vector: [Float]) {
        let strength = event.signal.strength
        decay(&centroid, to: event.date)
        let alpha = strength * max(minimumAlpha, 1 / (centroid.mass + 1))
        centroid.vector = normalized(zip(centroid.vector, vector).map { (1 - alpha) * $0 + alpha * $1 })
        centroid.weight += strength
        centroid.mass += strength
        centroid.eventIDs.insert(event.id)
        if event.signal == .like || !centroid.exemplarIsLike {
            centroid.exemplar = event.path
            centroid.exemplarIsLike = event.signal == .like
        }
    }

    private static func decay(_ centroid: inout TasteCentroid, to date: Date) {
        let days = date.timeIntervalSince(centroid.lastDate) / 86_400
        guard days > 0 else {
            return
        }
        centroid.weight *= Float(pow(0.5, days / halfLifeDays))
        centroid.lastDate = date
    }

    private static func mergeClosestPair(_ centroids: inout [TasteCentroid]) {
        var pair = (0, 1)
        var best: Float = -2
        for i in centroids.indices {
            for j in centroids.indices where j > i {
                let score = cosine(centroids[i].vector, centroids[j].vector)
                if score > best {
                    best = score
                    pair = (i, j)
                }
            }
        }
        let other = centroids.remove(at: pair.1)
        var kept = centroids[pair.0]
        let share = other.weight / max(kept.weight + other.weight, .leastNonzeroMagnitude)
        kept.vector = normalized(zip(kept.vector, other.vector).map { (1 - share) * $0 + share * $1 })
        kept.eventIDs.formUnion(other.eventIDs)
        kept.mass += other.mass
        if other.weight > kept.weight {
            kept.exemplar = other.exemplar
            kept.exemplarIsLike = other.exemplarIsLike
        }
        kept.weight += other.weight
        kept.lastDate = max(kept.lastDate, other.lastDate)
        centroids[pair.0] = kept
    }
}

/// Turn a candidate pool into one batch: slots per taste (by the square root of
/// its weight, so a dominant taste doesn't crowd out the rest), some wildcards
/// so the profile can still be surprised, near-copies dropped, order shuffled.
enum ExploreBatch {
    static let minimumWildcards = 2
    static let nearDuplicateCosine: Float = 0.92

    /// The familiar ↔ surprising dial, 0...1. One number moves three knobs:
    /// the random share, how hard picks push away from each other, and how
    /// evenly the tastes split the batch. The default is the original tuning:
    /// 15% random, penalty 0.35, slots by √weight.
    struct Mix: Equatable {
        static let standard = Mix(surprise: 0.2)

        var surprise: Double

        var wildcardShare: Double { 0.05 + 0.5 * clamped }
        var diversityPenalty: Float { Float(0.1 + 1.25 * clamped) }
        /// Weight exponent for taste slots: 0.75 lets the strongest taste lead,
        /// 0 gives every taste the same share.
        var weightExponent: Double { max(0, 0.75 - 1.25 * clamped) }

        private var clamped: Double { min(max(surprise, 0), 1) }
    }

    struct Candidate {
        let path: String
        let score: Float
        let taste: Int?
        let vector: [Float]
    }

    static func compose<R: RandomNumberGenerator>(candidates: [Candidate], weights: [Float], size: Int,
                                                  mix: Mix = .standard, using rng: inout R) -> [String] {
        var picked: [Candidate] = []
        let wildcards = weights.isEmpty ? size : min(size, max(minimumWildcards, Int((Double(size) * mix.wildcardShare).rounded())))
        let quotas = slots(for: weights, total: size - wildcards, exponent: mix.weightExponent)
        for (taste, quota) in quotas.enumerated() {
            let pool = candidates.filter { $0.taste == taste }
            pickDiverse(from: pool, count: quota, penalty: mix.diversityPenalty, into: &picked)
        }
        let random = candidates.filter { $0.taste == nil }
        pickInOrder(from: random, upTo: size, wanted: wildcards, into: &picked)
        // A thin taste or a small library leaves gaps: fill from whatever is left.
        pickDiverse(from: candidates.filter { $0.taste != nil }, count: size - picked.count,
                    penalty: mix.diversityPenalty, into: &picked)
        pickInOrder(from: random, upTo: size, wanted: size - picked.count, into: &picked)
        return picked.map(\.path).shuffled(using: &rng)
    }

    /// Largest-remainder split of `total` by each weight raised to `exponent`
    /// (the square root by default).
    static func slots(for weights: [Float], total: Int, exponent: Double = 0.5) -> [Int] {
        guard !weights.isEmpty, total > 0 else {
            return weights.map { _ in 0 }
        }
        let roots = weights.map { pow(Double(max($0, 0)), exponent) }
        let sum = max(roots.reduce(0, +), .leastNonzeroMagnitude)
        let exact = roots.map { $0 / sum * Double(total) }
        var result = exact.map { Int($0) }
        let byRemainder = exact.indices.sorted { exact[$0] - Double(result[$0]) > exact[$1] - Double(result[$1]) }
        for i in byRemainder.prefix(total - result.reduce(0, +)) {
            result[i] += 1
        }
        return result
    }

    /// Greedy maximal marginal relevance: good matches, unlike what's picked.
    private static func pickDiverse(from pool: [Candidate], count: Int, penalty: Float,
                                    into picked: inout [Candidate]) {
        var remaining = pool
        var added = 0
        while added < count {
            var best: (index: Int, value: Float)?
            for (i, candidate) in remaining.enumerated() {
                let closest = closestPicked(candidate, picked)
                if closest >= nearDuplicateCosine || picked.contains(where: { $0.path == candidate.path }) {
                    continue
                }
                let value = candidate.score - penalty * max(closest, 0)
                if best == nil || value > best!.value {
                    best = (i, value)
                }
            }
            guard let best else {
                return
            }
            picked.append(remaining.remove(at: best.index))
            added += 1
        }
    }

    private static func pickInOrder(from pool: [Candidate], upTo size: Int, wanted: Int,
                                    into picked: inout [Candidate]) {
        var added = 0
        for candidate in pool where added < wanted && picked.count < size {
            if picked.contains(where: { $0.path == candidate.path })
                || closestPicked(candidate, picked) >= nearDuplicateCosine {
                continue
            }
            picked.append(candidate)
            added += 1
        }
    }

    private static func closestPicked(_ candidate: Candidate, _ picked: [Candidate]) -> Float {
        picked.map { TasteProfile.cosine($0.vector, candidate.vector) }.max() ?? -1
    }
}
