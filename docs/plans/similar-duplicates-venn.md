# Find Similar, duplicates, and Venn upgrades

Status: built 2026-10-19. No new indexes. Everything uses the ML plugins'
existing fingerprints, or is computed on demand.

### As built (differs from the plan below)
- **Near-duplicates use CLIP, not FeaturePrint.** overlap-suggest only indexes
  tagged files; overlap-clip already covers every image, so it gained the
  `duplicates` capability. A blocked matrix product (cblas_sgemm) compares
  4,653 images in about 0.07 s.
- Similar threshold: a new plugin setting, `similarMinScore` (default 0.5).
  Image-to-image cosine runs much higher than text-to-image.
- Non-tag circles are encoded in the set's string (`@type:`, `@ext:`,
  `@year:`, `@search:`, `@similar:`), so regions and saved queries needed no
  new fields. Search and similar circles count only cataloged (tagged) files,
  like the rest of the Venn. Channel circles are left out: tags already cover
  that when "tag with channel" is on.
- The UpSet-style grid view was built, then taken out: it was hard to read
  (bars too heavy, no color coding). To revisit.
- The grid's key handler now acts only on keys from the main window. Before,
  ⌘⌫ in another window could trash the main grid's selection.
- Find Similar and similar circles drop hidden and vault files before calling
  the plugin.

## 1. Find Similar
- Right-click (or ⌘L) on one or more images → results ranked by likeness. With
  several images, they're averaged into one query.
- Contract: `SuggestRequest.similarTo: [path]`. A plugin declares the
  `similar` capability. overlap-clip reads the stored vectors, or embeds a file
  it hasn't seen yet (a remote preview, for example), averages them, and ranks
  the index by cosine. The inputs themselves are left out of the results.
- The host treats it like a text search: hits are in relevance order, the
  tag/type query narrows them, and the query bar shows a "Similar to" chip with
  thumbnails.
- Remote previews: "Find Similar in My Library" switches to the library and
  shows the results.

## 2. Duplicates
- Exact copies: the host finds them on demand. Group by file size, then hash
  only the files whose sizes collide.
- Near-duplicates: overlap-suggest's FeaturePrint vectors (2016 px decode,
  sensitive to how an image looks). New request field `duplicates
  {threshold}`; the response gains `groups: [[path]]`. Pairwise cosine runs
  in-process in blocks.
- Duplicates window: one row per group. Each row shows the images side by side
  with dimensions, size, date and tags, and a suggested keeper (highest
  resolution, then oldest). Actions:
  - **Keep this one**: the others go to the Trash, with their tags merged onto
    the keeper. Undoable.
  - **Merge tags only**.
  - **Not duplicates**: remembered in
    `~/Library/Application Support/Overlap/not-duplicates.json`, a small list
    of pairs.
- Scope: the current results or the whole library. A Strict ↔ Loose slider.

## 3. Venn
- Region actions in a region's right-click menu: Select, Tag…, New Board, Exclude.
- A "Show counts" toggle labels every region.
- A plain-English line under the query bar.
- Fixes:
  - Exact mode only applies to a single diagram.
  - Stale "AND only" comments.
  - The region-chip cap of 40.
- Non-tag sets: a circle can be a search (text), a similar-to set, a file
  type, or a date range. Membership is computed when the query runs, from
  plugin hits or file metadata.
- Grid (UpSet-style) view as an alternative to the Venn drawing when there
  are many sets.
