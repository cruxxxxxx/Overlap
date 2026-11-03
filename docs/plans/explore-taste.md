# Explore: batches steered by an on-device taste profile

Status: first version built 2026-11-01, to iterate by use. The old Explore tab
(Venn + tag map) became Find, now the sidebar's **Query** view. No new index: vectors come from overlap-clip.

## Flow
- Explore is a button at the start of the Library's results bar (⌘3); press it
  again to go back to the list. The sidebar stays the tag sidebar, with Liked
  and Tastes added on top. The Library tab remembers whether you were exploring.
- First visit: 24 random images. Like with the heart or Q; W for "less like this";
  Space for the next image, which draws a new batch past the last one; E for the
  next batch; R for Quick Look; ⌘[ goes back a batch. Q, W, Space and R work over
  Quick Look, but a new batch never draws under it. Rebind in Overlap ▸ Settings.
- Sidebar: Liked (all likes, can become a board), and one row per taste with its
  latest liked image. Click a taste to draw only from it; right-click to forget it.
- Tags in the sidebar filter batches; All Tags (top of the list, or in the bar)
  drops every filter, defaults included, to explore the whole library. It's the library's one query (Query's
  diagrams included), so excludes, defaults and type filters apply. A
  filter repeats its files once they've all been shown.
- Batches come from the tagged library only, never from what's in the queue.

## Signals
| signal | strength | can start a taste |
|---|---|---|
| Like | 1.0 | yes |
| Opened (Quick Look, double-click) | 0.4 | yes |
| Viewed (selected 4 s, app active) | 0.2 | no, only refines |
| Less like this | 1.0 | goes to separate avoid centroids (max 3) |

Scrolling past an image counts for nothing: in a random batch, not clicking isn't
evidence of dislike.

## Profile (`ExploreProfile.swift`)
- Up to 6 centroids. An event joins the nearest at cosine ≥ 0.55, else starts a
  new one; over the cap, the closest pair merges. 0.55 sits near the p99 of random
  pairs (0.58) in the real library, below the median nearest neighbor (0.66).
- EMA alpha = strength × max(0.12, 1 / (mass + 1)): a running mean early, then a
  steady drift. Weight halves every 45 days.
- The profile is a pure fold over the last 500 events; centroids are never
  stored. Unlike, forget, or a file becoming hidden removes events and refolds, so
  none of that image's embedding survives. This is why events carry their vectors.

## Batches
- Plugin returns the top 40 per taste, plus 72 random, with vectors (30-40 ms on
  4,718 images, no model load).
- 15% wildcards (at least 2). The rest split by √weight, picked by MMR (penalty
  0.35); anything at cosine ≥ 0.92 to a pick is dropped as a near-copy. Shuffled.
- Those are the defaults of the Familiar ↔ Surprising slider in the Explore bar
  (0...1, default 0.2, applies from the next batch). It moves all three: random
  share 5% → 55%, MMR penalty 0.1 → 1.35, taste split weight^0.75 → equal.
- Shown images aren't repeated until 5,000 others or the whole library has passed.

## Storage and privacy
`Application Support/Overlap/explore-profile.json`: events (path, signal, date,
vector) and seen paths, about 1.5 MB at the cap. Nothing leaves the Mac. Hidden and
vault files are dropped from results, never named to the plugin, and purged from
the log on every vault reconcile.

## Open questions
- Thresholds were calibrated on one library.
