# Visual Neighbors — Overlap similarity plugin

The real embed-and-nearest-neighbor suggester the reference `folderkind` plugin
stands in for. For each selected image it computes an **Apple Vision FeaturePrint**
(`VNGenerateImageFeaturePrintRequest` — free, on-device, no model download), finds
the *k* most visually similar files in your tagged library, and suggests the tags
those neighbors carry, weighted by similarity.

## What it suggests

For each selected **image**:
- the tags of its **k=7 nearest** already-tagged library images (cosine similarity
  on the FeaturePrint vector), each weighted by the summed similarity of the
  neighbors that carry it, normalized to a 0…1 confidence.
- tags below `MIN_CONFIDENCE` (0.30) or already on the file are dropped; at most 6
  tags per file.

This is the `wantsLibrary: true` pattern from `docs/PLUGINS.md`, implemented for
real: Overlap hands the plugin every tagged file + its tags, the plugin embeds
them, and borrows the closest matches' tags.

## Performance

FeaturePrint embeddings are **cached on disk** by `path + size + modDate` at
`~/Library/Application Support/Overlap/PluginCache/visionknn-featureprint.json`,
so only changed files are re-embedded between runs. First run over a large library
is the slow one; subsequent runs are near-instant.

## Quality

On a ~3,900-image hand-tagged library, FeaturePrint kNN measured **F1 ≈ 0.74**
(micro, 200-image holdout). A semantic embedding (SigLIP / MobileCLIP) scored
slightly higher (~0.78) but needs a bundled model; FeaturePrint is the
zero-dependency, ships-with-macOS choice. Swapping the embedding is a localized
change to `embed(_:)` — a natural future upgrade.

## Contract

Overlap writes a `SuggestRequest` JSON to stdin (with `library`) and reads a
`SuggestResponse` JSON from stdout; exit 0. See `Sources/PluginContract.swift` for
the authoritative types. `manifest.json` declares `wantsLibrary: true` and
`handles: ["image"]`.

## Build & install (dev)

```sh
bash plugins/install.sh          # builds every plugin and symlinks into Overlap
# or just this one:
cd plugins/visionknn && swiftc main.swift -o visionknn
```
