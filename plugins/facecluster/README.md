# Face Groups — Overlap clustering plugin

Groups the **selected** images by who is in them. For each image it extracts one
**Apple Vision faceprint** (128-dim, on-device) per detected face, clusters those
faceprints across the selection, and suggests a **"Person N"** tag per cluster
covering just the images that person appears in. Multi-face photos join several
clusters, so one image can receive several Person chips (⌥-click a chip to select
just its members).

This is the disjoint-groups-over-one-selection pattern from `docs/PLUGINS.md`
(like `mockcluster`, but real): each person cluster becomes its own chip with a
member-count badge.

## What it suggests

- Faces are clustered by **centroid-linkage** at cosine ≥ `0.84` (avoids the
  single-linkage chaining that merges different people into one blob).
- A cluster becomes a suggestion only if it spans **≥ 2 images** (`MIN_CLUSTER`).
- Persons are ranked by photo count — the most-photographed is `Person 1`.
- Each suggestion's confidence is that face's cohesion (cosine) with its cluster
  centroid.

`Person N` labels are positional within one Suggest run, not stable identities
across runs — rename the chip to a real name on apply if you like.

## Vision API note

Vision's face **embedding** (`VNCreateFaceprintRequest` / `-faceprint`) is not in
the public Swift API, so the plugin reaches it through the Objective-C runtime
(`NSClassFromString` + KVC). It runs entirely on-device (no model download, no
network). If a future macOS removes or renames the request, the plugin degrades to
returning **no suggestions** rather than crashing — one bad plugin never blocks the
app.

## Contract

Overlap writes a `SuggestRequest` JSON to stdin and reads a `SuggestResponse` JSON
from stdout; exit 0. See `Sources/PluginContract.swift` for the authoritative
types. `manifest.json` declares `wantsLibrary: false` (it clusters within the
selection) and `handles: ["image"]`.

## Build & install (dev)

```sh
bash plugins/install.sh
# or just this one:
cd plugins/facecluster && swiftc main.swift -o facecluster
```
