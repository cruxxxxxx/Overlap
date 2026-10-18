# Tag colors + browsing connected services in the main window

Status: built (2026-10-17). Decisions made:
- Services sit below Tags. A small "Connected Services" menu at the bottom of
  the sidebar switches each service's section on or off; with none on, nothing
  shows.
- Files saved by drag go to `<library>/Are.na/<Channel>/`.
- Preview cache cap is 500 MB.
- Dragging onto a tag adds the channel tag only when the plugin setting
  `tagSavedWithCollection` is on (default off). A plain Save always adds it.

### As built (differs from the plan below)
- **Colors are never stored by Overlap.** On each catalog load, the color is read
  from one file per tag. Setting a color writes it to every file that has the
  tag. Nothing goes in UserDefaults, so hidden tag names don't leak there.
- **No full-size fetch.** The cached preview (~1200 px) is enough for Quick Look
  and the preview pane.
- **Drags carry the preview file's URL.** `TagStore.addTag` and the board's drop
  handler save remote previews first, via `RemoteResultsHandler`, then act on the
  saved files. So the sidebar needed no new drop type. Dragging to Finder copies
  the preview, not the original file.
- **`RemoteBrowseModel` is its own object**, in the main window's environment, not
  owned by `SourceStore`. Clicking a tag with a remote selection saves the
  selection and tags it; with nothing selected, it returns to the library.
- **Tag suggestions are off in remote mode.** Plugins would otherwise index
  cache paths.

## 1. Tag colors

### How macOS does it
- Each file stores its own tag colors. The `com.apple.metadata:_kMDItemUserTags`
  xattr is a plist array of `"name\nN"` entries, where N is 0–7:
  none, gray, green, purple, blue, yellow, red, orange. Finder reads the color
  from there.
- Finder's own tag list (sidebar, Tags preferences) is a separate registry.
  There is no public API to write it, so we leave it alone.

### Bug found
`TagIO.setTags` writes through `URLResourceKey.tagNamesKey`, which resets every
entry to `\n0`. Tested: a file with `"keep\n6"` (red) became `"keep\n0"` after
Overlap added a tag. **So today, any Overlap edit removes colors that were set in
Finder.**

### Plan
- `TagIO` reads and writes the xattr directly and keeps each tag's index.
  Lookups by name still go through `tagNamesKey` / Spotlight.
- New `TagColor` enum with the 8 Finder indices. Each case maps to the same
  `NSColor` that Finder uses.
- A per-tag color map in UserDefaults (`tagColors`), filled in lazily when a tag
  is first shown, from the files Overlap already loaded. It is not an index:
  it's a small map of name to color.
- In the sidebar, tag rows get a color dot. The context menu gets **Color ▸**
  with the 7 colors plus None. Choosing one updates the map, rewrites the index
  in every file that has the tag (so Finder matches), and is undoable.
- Tag chips (footer, quick-tag bar, suggestions) use the color as a tint.
- New tags created in Overlap start with no color, as in Finder.

## 2. Connected services in the main window (no pop-out)

### Goals
- Browsing works like the library: same grid, thumbnail size, selection,
  Space for Quick Look, preview pane, and footer.
- Your tags stay in the sidebar. **Drag a remote image onto a tag to save it to
  the library with that tag.** The channel tag (`arena/…`) becomes optional.
- The host stays service-agnostic. All code is about "connected services" and
  "remote items", and nothing names Are.na. The library only gets files you
  actually save.

### Shape
- **Mode.** `LibraryMode` gains `.remote`. `TagStore` only stores the mode. The
  remote state (current scope or collection, items, cursor, selection) lives in a
  new `RemoteBrowseModel` that `SourceStore` owns, so `TagStore` stays
  remote-free.
- **Sidebar.** A "Connected Services" section under the tags appears only when a
  source plugin is enabled. Per service it shows:
  - the plugin's `browseScopes` (Feed, Following, My Channels, Search)
  - the synced collections
  - "Open Link…"

  Clicking any of these switches the detail pane to remote results. Clicking a
  tag returns to the library.
- **Preview cache = local files.** Each remote tile's preview downloads to
  `~/Library/Caches/Overlap/Remote/<plugin>/<remoteId>.<ext>`. This is a
  disposable cache with a size cap (default 500 MB, oldest files removed first),
  not an index. A tile is then a normal `FileItem` pointing at that file, so
  `ThumbnailCell`, `PreviewPane`, Quick Look, and the keyboard handling are all
  reused unchanged.
- **Full size on demand.** Space or the preview pane on a tile that only has a
  small preview runs the plugin's `fetch` into the same cache, then Quick Look
  shows the full image.
- **Header row** in the same style as `QueryBar`:
  - breadcrumb: Service › Scope › Collection
  - search field, only when the scope takes a query
  - borderless icon buttons: Open on Web, Related, and a `⋯` menu with
    Import All / Sync / Edit / Link to Board

  Progress uses the existing warm-up strip.
- **Grid behavior.**
  - Collections appear as folder-like tiles; double-click opens one, like
    drilling into a folder in the queue.
  - Blocks appear as images. Saved ones show a check badge, and selecting one
    shows its local tags in the footer.
  - Paging loads more when you scroll near the end.
- **Saving.**
  - Drag onto a sidebar tag saves the file and tags it with that tag. This
    works for the whole selection.
  - Drag onto a mood board saves it and adds it to the board.
  - Drag to Finder writes the full file there, via a file promise.
  - The quick-tag bar works on a remote selection: typing a tag saves, then
    tags.
  - Context menu and ⌘S: "Save to Library".
  - Every save also records where the file came from (xattr plus
    where-from), so "Open on Web" and sync still work.
- **Drag payload.** A custom UTType `com.overlap.remote-item` (plugin id plus
  remote id), not a file URL, so the sidebar can't tag the cache file by
  mistake. The sidebar's drop handler accepts both types and passes remote
  items to a generic `remoteDropHandler` that `SourceStore` provides.
- **Removed.** The `SourceBrowserView` window and its custom buttons. The
  Sources menu's "Browse…" items switch the main window instead. The Connected
  Services window stays for account, token, and synced links.

### Decisions needed
1. **Add the channel tag when saving by drag?**
   - Recommended: no. Use only the tag you dropped on. The origin is still kept
     in the xattr.
   - Alternative: drop tag plus `arena/<channel>`.
2. **Where saved files go.**
   - Recommended: keep `<library>/Are.na/<Channel>/`, so files stay grouped by
     where they came from.
   - Alternative: a flat `<library>/Are.na/`.
3. **Preview cache cap.** 500 MB, or a setting.

## Phases
1. Fix color preservation in `TagIO`, then add tag colors (sidebar dot, Color
   menu, chips). Ships on its own.
2. Remote mode: cache, `RemoteBrowseModel`, sidebar section, grid reuse, header
   row. Delete the pop-out.
3. Quick Look and preview pane with full-size fetch.
4. Drag to tag, board, and Finder. Quick-tag bar save. Saved badges.
5. Headless test additions (fetch to cache, save with a drop tag), docs,
   README.
