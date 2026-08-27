<div align="center">

<img src="Resources/icon-1024.png" width="128" alt="Overlap icon">

# Overlap

**A native macOS app for tagging and querying any file with Finder tags — with the boolean/Venn queries, batch workflows, and content-based suggestions Finder lacks.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift 5](https://img.shields.io/badge/Swift-5-orange)

</div>

<!-- Add a wide hero shot as docs/screenshots/hero.png and uncomment:
<div align="center"><img src="docs/screenshots/hero.png" width="900" alt="Overlap"></div>
-->

Overlap reads and writes real macOS extended-attribute tags
(`com.apple.metadata:_kMDItemUserTags`), so everything stays interoperable with
Finder, Spotlight, and other tag tools — nothing is locked in a private database.
It works on **any file type** (images, video, audio, PDFs, text, archives, even
folders), not just photos.

---

## Screenshots

| Explore — Venn query | Tags — grid + preview |
|---|---|
| ![Explore](docs/screenshots/explore-venn.png) | ![Grid](docs/screenshots/grid-preview.png) |
| **Queue — intake & drill** | **Suggestions — plugins** |
| ![Queue](docs/screenshots/queue.png) | ![Suggest](docs/screenshots/suggest.png) |

---

## Features

- **Boolean & Venn queries** — tri-state tag chips (include / exclude / off) with
  **All** (AND), **Any** (OR), **Exact** (only these tags), and multi-diagram
  **Groups** (`(A OR B) AND C`). Paint individual regions of a Venn diagram to
  select precise tag intersections; the diagram is laid out from the real data.
- **Saved queries** — name and reuse a whole Venn setup (diagrams + excludes).
- **Any file type** — images, video (inline playback), audio, PDFs, text,
  archives, and folders. Filter results by **kind** or **extension**.
- **Live results grid** — QuickLook thumbnails (ImageIO fallback for odd files),
  animated GIFs, adjustable size, multi-select, keyboard navigation.
- **Split preview** — a large live preview with per-type info (resolution,
  duration, size, dates) and image EXIF (camera, lens, exposure).
- **Slideshow** — auto-advancing preview over the current results, arrow-key nav,
  interval + shuffle.
- **Fast tagging** — quick-tag bar (`T`, type-ahead), drag-onto-tag,
  click-to-apply; create / rename / **merge** / delete tags; two-level taxonomy.
- **Queue** — watch folders for untagged files, tag them, then **Apply** to move
  them into your library. Configurable recursion depth and **Finder-style
  drill-in** with a breadcrumb.
- **Tag suggestions** — an **out-of-process plugin system**: drop in an executable
  and get content-based tag suggestions (see [Plugins](#plugins)).
- **Hidden tags** — passcode-gate sensitive tags; per-tag default include/exclude.
- **Undo/redo** across every mutation (⌘Z / ⌘⇧Z), plus Stats, Fix Extension,
  Reveal, Export, and drag-out to other apps.

---

## Install / Build

Requires **Xcode 15+** (macOS 13+ target). The project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
brew install xcodegen      # one-time
xcodegen generate
open Overlap.xcodeproj      # then ⌘R
```

Overlap runs **unsandboxed** (Developer ID / local use) so it can read and write
Finder tags across your folders.

---

## Usage

1. **Point it at a folder** — the toolbar folder button (default `~/Pictures`).
   Spotlight must have indexed the scope for tags to appear.
2. **Filter** — click tags in the sidebar to cycle include → exclude → off, or
   switch to **Explore** and paint Venn regions. Narrow by file **Type** as needed.
3. **Tag** — select files, press **T**, type a tag, ⏎. Tags are written to the
   files themselves, so Finder and Spotlight see them immediately.
4. **Queue** — add watched folders (e.g. Downloads), set the subfolder depth,
   tag the untagged items, then **Apply** to move them into your library.
5. **Suggest** — select a file and click **✨ Suggest** to get tag suggestions
   from any installed plugin.

> Tags live on the files. Deleting a tag in Overlap removes it from the file
> everywhere — Finder, Spotlight, other tools.

---

## Architecture

A single `@MainActor` store, `TagStore`, is the source of truth; every surface
(grid, sidebar, Venn, stats, queue) reads from it.

- **Catalog** — an `NSMetadataQuery` (`kMDItemUserTags LIKE '*'`) finds every
  tagged item under the scope, of any type. Metadata is parsed **off the main
  thread** (each `NSMetadataItem` attribute read is a synchronous XPC call), and
  a Codable snapshot is cached to `~/Library/Application Support/Overlap/` so tags
  appear instantly on the next launch before Spotlight re-gathers. Spotlight
  reports files under both `/Users/…` and `/System/Volumes/Data/Users/…`
  firmlink paths; these are canonicalized to one form to avoid duplicates.
- **Query model** — `VennGroup` is an ordered set of tags plus optional painted
  regions (membership bitmasks). The query evaluates as **sum-of-products**: `OR`
  starts a new clause, `AND` binds diagrams within a clause. Everything — sidebar
  tri-state, chips, Venn, saved queries — edits this one model.
- **Venn layout** (`VennLayout.swift`) — a deterministic, data-driven layout:
  every pair of circles targets a distance derived from its real overlap, then a
  spring relaxation + hard constraints settle it (sharing pairs must overlap,
  disjoint pairs may not, subsets nest). It's pure geometry with **no SwiftUI
  dependency**, so a headless validator (`scripts/validate-venn.swift`) can
  replay the exact layout and check that every selected region renders sensibly.
- **Tag I/O** — writes go through `URLResourceValues.tagNames`; every mutation is
  wrapped in an undo/redo step.

---

## Plugins

Tag **suggestions** come from an **out-of-process plugin system** — plugins are
standalone executables, discovered at runtime, that never link against the app.
This keeps suggestion logic (e.g. a future Apple Vision + clustering engine)
shippable **separately** from Overlap, in any language.

**How it works**

- Drop a plugin folder in `~/Library/Application Support/Overlap/Plugins/<name>/`
  containing a `manifest.json` and the executable it names.
- When you click **✨ Suggest**, Overlap runs each applicable plugin as a child
  process: it writes a JSON `SuggestRequest` (the selected files + optionally the
  whole tagged-library corpus) to **stdin**, and reads a JSON `SuggestResponse`
  (`[{path, tag, confidence, source}]`) from **stdout**. Results are merged,
  ranked by confidence, and shown as tap-to-apply chips.
- Each plugin has its own timeout; a crash, non-zero exit, or malformed output is
  a silent no-op — one bad plugin never blocks the others or the app.

**Manifest**

```json
{ "name": "Folder & Neighbors", "id": "com.overlap.folderkind", "version": "1.0.0",
  "protocolVersion": 1, "exec": "folderkind", "handles": ["*"],
  "batch": true, "wantsLibrary": true, "timeoutMs": 4000 }
```

`wantsLibrary` opts the plugin into the full tagged corpus, so a clustering
plugin can embed the library and suggest the tags of the most similar files.

**Reference plugin** — `plugins/folderkind/` is a tiny, dependency-free Swift
plugin (parent folder + file kind + neighbor tags from the corpus) that proves
the whole pipe. Build and install it for local testing:

```sh
bash plugins/install.sh     # builds every plugin and symlinks it into the Plugins dir
```

The contract types live in `Sources/PluginContract.swift`.

---

## Credits

Overlap is inspired by **[Tagception](https://madebyevan.com/tagception/)** by
**[Evan Wallace](https://madebyevan.com/)** — the project that showed how good a
Finder-tag browser can feel. Overlap builds on that idea with boolean/Venn
queries, any-file-type support, and a plugin system.

---

## License

Overlap is free software under the **[GNU General Public License v3.0](LICENSE)**.
You may use, study, share, and modify it — and any derivative you distribute must
also be open source under the GPL. It stays free, forever.
