# Mock Cluster (dev-only)

Fake clustering plugin for exercising the cluster-chip UX. Buckets the selected
files into 2–4 deterministic groups (stable filename hash — no real similarity)
and suggests one tag per group, covering only that group's files.

Expected behavior in the app after `bash plugins/install.sh`:

1. Select a bunch of files, hit **✨ Suggest**.
2. Chips appear like `Cluster Alpha (12) 90%` — the count badge shows the chip
   covers a subset of the selection.
3. **⌥-click** a chip to select just that group in the grid (inspect it).
4. **Click** a chip to tag exactly its member files; the chip disappears, the
   others stay.

Delete the `mockcluster` symlink from
`~/Library/Application Support/Overlap/Plugins/` when done testing.
