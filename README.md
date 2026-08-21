# Overlap

A native macOS app for browsing, tagging, and organizing images by **Finder tags** —
with the boolean queries and batch workflows Finder and other tag tools lack.

Built on real macOS extended-attribute tags (`com.apple.metadata:_kMDItemUserTags`),
so everything stays interoperable with Finder, Spotlight, and tools like Tagception.

## Features

- **Boolean filtering** — tri-state tag chips (include / exclude / off) with modes:
  - **All** (AND), **Any** (OR), **Only** (exact tag set), **Groups** (OR within a
    letter, AND across letters, e.g. `(Fashion OR Streetwear) AND Cover`).
- **Live results grid** — QuickLook thumbnails (with ImageIO fallback for
  mis-named / odd-profile files), animated GIFs, adjustable size.
- **Split preview** — large live preview with file insights (type, resolution,
  size, dates) and EXIF (camera, lens, exposure, color).
- **Fast tagging** — quick-tag bar (`T`, type-ahead, applies to selection),
  drag-onto-tag, click-to-apply, sidebar taxonomy creation (`cat/…`, `type/…`).
- **Queue** — watch folders (e.g. Downloads) for untagged images, tag them,
  then **Apply** to move them into the library.
- **Tag management** — create / rename / **merge** / delete tags, drag-reorder
  top-level tags, subtags via `/`.
- **File actions** — Reveal, Copy Path, Export, **Fix Extension**, Move to Trash,
  drag out to other apps.
- **Sorting** — name, type, date modified/created, size (asc/desc).
- **Stats panel** — totals, size, type breakdown, top tags, untagged count.
- **Multi-select** (click / ⌘-click / shift-range), keyboard grid navigation,
  and **undo/redo** across every mutation (⌘Z / ⌘⇧Z).

## Build

Requires Xcode 15+ (macOS 13+ target). The project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
brew install xcodegen      # if not installed
xcodegen generate
open Overlap.xcodeproj      # then ⌘R
```

The app runs unsandboxed (local personal use) so it can read/write tags across
your library folders.

## Usage notes

- Point it at a folder with the toolbar folder button (default `~/Pictures`).
- Spotlight must index the scope for tags to appear.
- Tags are written to the files themselves — deleting a tag in the app removes it
  from the file everywhere.
