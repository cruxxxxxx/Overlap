<div align="center">

<img src="Resources/icon-1024.png" width="120" alt="Overlap icon">

# Overlap

**Tag and query any file with native macOS Finder tags — boolean/Venn queries, batch workflows, and content-based suggestions.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
&nbsp;![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
&nbsp;![Swift 5](https://img.shields.io/badge/Swift-5-orange)

</div>

Overlap reads and writes real macOS tags (`com.apple.metadata:_kMDItemUserTags`),

so everything stays interoperable with Finder, Spotlight, and other tag tools —

nothing is locked in a private database. Works on **any file type**, not just photos.

<br>

## Screenshots

| Explore — Venn query | Tags — grid + preview |
|---|---|
| ![Explore](docs/screenshots/explore-venn.png) | ![Grid](docs/screenshots/grid-preview.png) |
| **Queue — intake & drill** | **Explore — tag map** |
| ![Queue](docs/screenshots/queue.png) | ![Tag map](docs/screenshots/tag-map.png) |

<br>

## Features

- **Boolean & Venn queries** — include / exclude / off chips; All, Any, Exact, and multi-diagram groups. Paint Venn regions to select exact intersections.

- **Any file type** — images, video, audio, PDFs, text, archives, folders. Filter by kind or extension.

- **Fast tagging** — quick-tag bar (`T`), drag-onto-tag, create / rename / merge / delete.

- **Queue** — watch folders for untagged files, tag, then Apply to move them in. Depth limit + Finder-style drill-in.

- **Saved queries, slideshow, split preview + EXIF, hidden (passcode) tags, stats, undo/redo.**

- **Tag suggestions** via a plugin extension point — see [docs/PLUGINS.md](docs/PLUGINS.md).

<br>

## Build

Requires Xcode 15+ (macOS 13+). Generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Overlap.xcodeproj      # ⌘R
```

Runs unsandboxed so it can read/write Finder tags across your folders.

<br>

## Usage

1. Point it at a folder (toolbar folder button). Spotlight must have indexed it.

2. Filter by clicking sidebar tags, or paint regions in **Explore**.

3. Select files, press **T**, type a tag, ⏎.

4. **Queue**: watch a folder, tag the untagged, **Apply** to move them in.

> Tags live on the files — deleting one in Overlap removes it everywhere.

<br>

## Architecture

- **Catalog** — an `NSMetadataQuery` over `kMDItemUserTags` finds every tagged file; parsed off-main and cached to Application Support for instant launch.

- **One model** — `TagStore` is the single source of truth; the query is a `VennGroup` list evaluated as sum-of-products (OR splits clauses, AND binds within).

- **Venn layout** — deterministic, data-driven geometry (`VennLayout.swift`), SwiftUI-free so a headless validator (`scripts/validate-venn.swift`) can replay it.

- **Tag I/O** — `URLResourceValues.tagNames`, every mutation undoable.

<br>

## Plugins

Suggestions come from **out-of-process plugins** — standalone executables, any language, discovered at runtime. Overlap pipes a JSON request in and reads suggestions out.

→ **[How to write one](docs/PLUGINS.md).**

<br>

## Credits

Inspired by **[Tagception](https://madebyevan.com/tagception/)** by **[Evan Wallace](https://madebyevan.com/)**.

<br>

## License

[GNU GPL v3.0](LICENSE) — free software. Derivatives must stay open source under the GPL. Free, forever.
