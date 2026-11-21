// Headless check of the Explore taste profile and batch composition, on
// synthetic clusters: tastes stay separate, refolding really forgets, batches
// honor slots, wildcards and near-duplicate rejection.
//
// Top-level code must be compiled as main.swift, so copy it first:
//   mkdir -p /tmp/te && cp scripts/test-explore.swift /tmp/te/main.swift
//   swiftc Sources/ExploreProfile.swift Sources/ExploreKeys.swift /tmp/te/main.swift -o /tmp/test-explore && /tmp/test-explore
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok {
        failures += 1
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var rng = SeededRNG(state: 7)

let dim = 64
func axis(_ i: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dim)
    v[i] = 1
    return v
}
func near(_ center: [Float], jitter: Float = 0.25) -> [Float] {
    TasteProfile.normalized(center.map { $0 + Float.random(in: -jitter...jitter, using: &rng) / Float(dim).squareRoot() })
}
var clock = Date(timeIntervalSince1970: 1_800_000_000)
func event(_ path: String, _ signal: TasteSignal, _ vector: [Float]) -> TasteEvent {
    clock.addTimeInterval(60)
    return TasteEvent(path: path, signal: signal, date: clock, vector: TasteProfile.data(vector))
}

print("fold")
var log = (0..<8).map { event("a\($0)", .like, near(axis(0))) }
log += (0..<4).map { event("b\($0)", .like, near(axis(1))) }
var profile = TasteProfile.fold(log, now: clock)
check(profile.tastes.count == 2, "two clusters make two tastes, got \(profile.tastes.count)")
check(TasteProfile.cosine(profile.tastes[0].vector, axis(0)) > 0.8, "heaviest taste sits on its cluster")
check(TasteProfile.cosine(profile.tastes[1].vector, axis(1)) > 0.8, "second taste sits on its cluster")
check(abs(profile.tastes[0].vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.001, "centroids stay normalized")

let glance = TasteProfile.fold([event("g", .viewed, axis(2))], now: clock)
check(glance.tastes.isEmpty, "a glance can't start a taste")
let refined = TasteProfile.fold(log + [event("a", .viewed, near(axis(0)))], now: clock)
check(refined.tastes.count == 2, "a glance joins an existing taste")

let spread = (0..<10).map { event("s\($0)", .like, axis($0)) }
let spreadProfile = TasteProfile.fold(spread, now: clock)
check(spreadProfile.tastes.count == 10, "unrelated likes stay separate tastes, got \(spreadProfile.tastes.count)")
check(spreadProfile.drawnTastes.count == TasteProfile.maxTastes, "batches draw from the strongest few")
let leader = TasteProfile.fold(spread + (0..<3).map { event("s9-\($0)", .like, near(axis(9))) }, now: clock)
check(leader.drawnTastes.first.map { TasteProfile.cosine($0.vector, axis(9)) > 0.8 } == true, "a taste liked more rises to the top")

let less = TasteProfile.fold([event("x", .lessLikeThis, axis(3))], now: clock)
check(less.tastes.isEmpty && less.avoids.count == 1, "less-like-this goes to avoids, not tastes")

print("decay and drift")
let old = event("old", .like, axis(4))
let recent = event("new", .like, axis(5))
let later = recent.date.addingTimeInterval(45 * 86_400)
let aged = TasteProfile.fold([old, recent], now: later)
check(abs(aged.tastes[0].weight - 0.5) < 0.01, "weight halves in one half-life, got \(aged.tastes[0].weight)")
let target = near(axis(0), jitter: 0.1)
var drifting = [event("d0", .like, axis(0))]
drifting += (1..<40).map { event("d\($0)", .like, TasteProfile.normalized(zip(axis(0), axis(6)).map { 0.75 * $0 + 0.66 * $1 })) }
let drifted = TasteProfile.fold(drifting, now: clock).tastes[0]
check(TasteProfile.cosine(drifted.vector, axis(6)) > 0.6, "repeated likes pull an EMA along")
_ = target

print("forgetting")
let without = log.filter { $0.path != "b0" }
check(TasteProfile.fold(without, now: clock).tastes.flatMap(\.eventIDs).count == log.count - 1, "refold drops a removed event")
let onlyA = log.filter { $0.path.hasPrefix("a") }
check(TasteProfile.fold(onlyA, now: clock).tastes.count == 1, "removing a taste's events removes the taste")
let id = log.last!.id
check(!TasteProfile.fold(log.filter { $0.id != id }, now: clock).tastes.contains { $0.eventIDs.contains(id) }, "no centroid names a removed event")

print("slots")
check(ExploreBatch.slots(for: [4, 1], total: 9) == [6, 3], "slots follow the square root of weight")
check(ExploreBatch.slots(for: [1, 1, 1], total: 10).reduce(0, +) == 10, "slots add up")
check(ExploreBatch.slots(for: [], total: 10) == [], "no tastes, no slots")

print("compose")
func cand(_ path: String, _ taste: Int?, _ v: [Float], score: Float = 0.7) -> ExploreBatch.Candidate {
    ExploreBatch.Candidate(path: path, score: score, taste: taste, vector: v)
}
let pool = (0..<40).map { cand("t0-\($0)", 0, near(axis(0), jitter: 3)) }
    + (0..<40).map { cand("t1-\($0)", 1, near(axis(1), jitter: 3)) }
    + (0..<40).map { cand("r-\($0)", nil, near(axis(7 + $0 % 20), jitter: 3)) }
let batch = ExploreBatch.compose(candidates: pool, weights: [1, 1], size: 24, using: &rng)
check(batch.count == 24, "full batch")
check(Set(batch).count == 24, "no repeats")
let t0 = batch.filter { $0.hasPrefix("t0") }.count, t1 = batch.filter { $0.hasPrefix("t1") }.count
let wild = batch.filter { $0.hasPrefix("r-") }.count
check(wild == 4, "15% wildcards, got \(wild)")
check(t0 == 10 && t1 == 10, "even tastes split evenly, got \(t0)/\(t1)")

let cold = ExploreBatch.compose(candidates: pool.filter { $0.taste == nil }, weights: [], size: 24, using: &rng)
check(cold.count == 24 && cold.allSatisfy { $0.hasPrefix("r-") }, "cold start is all random")

let copies = (0..<30).map { cand("c\($0)", 0, axis(0)) } + (0..<30).map { cand("o\($0)", nil, near(axis(8 + $0 % 20), jitter: 3)) }
let deduped = ExploreBatch.compose(candidates: copies, weights: [1], size: 24, using: &rng)
check(deduped.filter { $0.hasPrefix("c") }.count == 1, "near-copies collapse to one")
check(deduped.count == 24, "gaps fill from the random pool")

let tiny = ExploreBatch.compose(candidates: [cand("only", nil, axis(0))], weights: [], size: 24, using: &rng)
check(tiny == ["only"], "a tiny library gives a short batch")
check(ExploreBatch.compose(candidates: [], weights: [1], size: 24, using: &rng).isEmpty, "no candidates, empty batch")

print("familiar ↔ surprising")
let standard = ExploreBatch.Mix.standard
check(abs(standard.wildcardShare - 0.15) < 1e-9 && abs(standard.diversityPenalty - 0.35) < 1e-6
      && abs(standard.weightExponent - 0.5) < 1e-9, "the default keeps the original tuning")
func wildcards(_ surprise: Double) -> Int {
    ExploreBatch.compose(candidates: pool, weights: [1, 1], size: 24, mix: .init(surprise: surprise), using: &rng)
        .filter { $0.hasPrefix("r-") }.count
}
let familiarWild = wildcards(0), surprisingWild = wildcards(1)
check(familiarWild == 2, "familiar keeps the minimum of random picks, got \(familiarWild)")
check(surprisingWild == 13, "surprising makes over half the batch random, got \(surprisingWild)")
check(ExploreBatch.slots(for: [9, 1], total: 10, exponent: ExploreBatch.Mix(surprise: 1).weightExponent) == [5, 5],
      "surprising shares the batch evenly between tastes")
let familiarSplit = ExploreBatch.slots(for: [9, 1], total: 10, exponent: ExploreBatch.Mix(surprise: 0).weightExponent)
check(familiarSplit[0] >= 8, "familiar lets the strong taste lead, got \(familiarSplit)")
check(ExploreBatch.Mix(surprise: 5).wildcardShare == ExploreBatch.Mix(surprise: 1).wildcardShare, "the dial is clamped")
let tight = (0..<40).map { cand("k\($0)", 0, near(axis(0), jitter: 1.5), score: 0.9) }
    + (0..<40).map { cand("w\($0)", 0, near(axis(9), jitter: 1.5), score: 0.6) }
func spreadOut(_ surprise: Double) -> Int {
    ExploreBatch.compose(candidates: tight, weights: [1], size: 10, mix: .init(surprise: surprise), using: &rng)
        .filter { $0.hasPrefix("w") }.count
}
check(spreadOut(1) > spreadOut(0), "surprising reaches past the closest matches")

print("keys")
var keymap = ExploreKeymap()
check(keymap.action(forKeyCode: 12) == .like && keymap.action(forKeyCode: 49) == .nextImage, "defaults: Q likes, Space steps")
check(keymap.assign(ExploreKey(keyCode: 37, label: "L"), to: .like), "a free key binds")
check(keymap.action(forKeyCode: 37) == .like && keymap.action(forKeyCode: 12) == nil, "rebinding frees the old key")
check(keymap.assign(ExploreKey(keyCode: 13, label: "W"), to: .like), "a taken key binds")
check(keymap.key(for: .like).keyCode == 13 && keymap.key(for: .less).keyCode == 37, "a taken key trades places")
check(!keymap.assign(ExploreKey(keyCode: 17, label: "T"), to: .like), "T stays reserved")
check(keymap.key(for: .like).keyCode == 13, "a refused key changes nothing")
let keymapData = try! JSONEncoder().encode(keymap)
check(try! JSONDecoder().decode(ExploreKeymap.self, from: keymapData) == keymap, "keymap survives saving")

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
