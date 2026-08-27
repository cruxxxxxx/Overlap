# Folder & Neighbors — Overlap reference suggestion plugin

A trivial, dependency-free reference implementation of the Overlap suggestion
plugin contract. It proves the whole pipe (stdin request → stdout suggestions →
merge → chip → apply) without any Vision/ML, and it exercises the **library
corpus** so the future Vision + clustering plugin can drop in unchanged.

## What it suggests

For each selected file:
- the **parent folder** name (confidence 0.9)
- the file **kind** — image/video/pdf/… (0.6)
- **neighbor tags** (0.4–0.7): the tags most common among already-tagged library
  files that share this file's folder or kind — a stand-in for "similar files'
  tags"

## Contract

Overlap writes a `SuggestRequest` JSON to stdin and reads a `SuggestResponse`
JSON from stdout; exit 0. Dates are ISO-8601. See `Sources/PluginContract.swift`
in the app for the authoritative types. The manifest (`manifest.json`) declares
`wantsLibrary: true` so Overlap includes every tagged file (+ its tags) in the
request.

## Build & install (dev)

```sh
bash ../install.sh          # builds every plugin here and symlinks into the Plugins dir
# or just this one:
swiftc main.swift -o folderkind
mkdir -p ~/Library/Application\ Support/Overlap/Plugins
ln -sf "$PWD" ~/Library/Application\ Support/Overlap/Plugins/folderkind
```

Then in Overlap: select a file, click the **✨ Suggest** button in the tag bar.

## Writing your own plugin

Ship a directory with a `manifest.json` + an executable it names, drop it in
`~/Library/Application Support/Overlap/Plugins/`. Any language works — read the
JSON request on stdin, write suggestions on stdout. Nothing links against the
app.
