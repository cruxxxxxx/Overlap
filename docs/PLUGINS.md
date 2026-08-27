# Writing an Overlap suggestion plugin

Overlap has one extension point: **tag suggestions**. A plugin is a standalone
executable — in **any language** — that Overlap runs to suggest tags for the
selected files. Nothing links against the app; plugins ship and update
independently.

Today Overlap includes one reference plugin (`plugins/folderkind/`). This page
is how to write your own.

---

## How it works

1. You install a plugin under
   `~/Library/Application Support/Overlap/Plugins/<name>/`.

2. When the user clicks **✨ Suggest**, Overlap runs your executable as a child
   process.

3. Overlap writes a JSON **request** to your **stdin**.

4. You write a JSON **response** to **stdout** and exit `0`.

5. Overlap merges every plugin's suggestions, ranks them by confidence, and shows
   them as tap-to-apply chips.

A crash, non-zero exit, timeout, or malformed output is ignored — one bad plugin
never blocks the others or the app.

---

## Layout

```
~/Library/Application Support/Overlap/Plugins/
  myplugin/
    manifest.json
    myplugin          # the executable named by manifest.exec
```

## Manifest

```json
{
  "name": "My Plugin",
  "id": "com.example.myplugin",
  "version": "1.0.0",
  "protocolVersion": 1,
  "exec": "myplugin",
  "handles": ["*"],
  "batch": true,
  "wantsKnownTags": false,
  "wantsLibrary": false,
  "timeoutMs": 5000
}
```

| field | meaning |
|---|---|
| `exec` | executable path, **relative to the manifest dir** |
| `handles` | file kinds you handle — `image`/`video`/`audio`/`pdf`/`text`/`archive`/`folder`/`other`, or `["*"]` for all |
| `wantsKnownTags` | include the user's full tag vocabulary in the request |
| `wantsLibrary` | include the whole tagged-library corpus (for similarity/clustering) |
| `timeoutMs` | kill the process after this long |

---

## Request (stdin)

```json
{
  "protocolVersion": 1,
  "files": [
    { "path": "/…/foo.png", "kind": "image", "ext": "png",
      "tags": [], "size": 12345, "modDate": "…", "createdDate": "…" }
  ],
  "knownTags": ["Art", "Fashion", "…"],
  "library": [
    { "path": "/…/bar.png", "kind": "image",
      "tags": ["Art", "Illustration"], "modDate": "…" }
  ]
}
```

`knownTags` and `library` are present only if your manifest opts in. Dates are
ISO-8601. Your plugin reads file contents from `path` itself (Overlap is
unsandboxed, so plugins have normal filesystem access).

## Response (stdout)

```json
{
  "protocolVersion": 1,
  "suggestions": [
    { "path": "/…/foo.png", "tag": "Illustration", "confidence": 0.9, "source": "myplugin" }
  ]
}
```

- `path` must match a request file, or the suggestion is dropped.
- `confidence` is `0…1` (clamped).
- Emit tags already on the file if you like — Overlap filters them out.

The authoritative types live in
[`Sources/PluginContract.swift`](../Sources/PluginContract.swift).

---

## Similarity plugins (`wantsLibrary`)

Set `wantsLibrary: true` and Overlap hands you every already-tagged file plus its
tags. The intended pattern: **embed** those files, **cluster** or nearest-
neighbor the target against them, and suggest the tags its closest matches carry.
Cache your embeddings by `path` + `modDate` so you only re-embed what changed.

This is how a future Apple Vision + clustering plugin drops in with **zero app
changes**.

---

## Reference plugin

`plugins/folderkind/` is a tiny, dependency-free Swift plugin: it suggests the
parent folder name, the file kind, and the most common tags among library files
in the same folder/kind. Build and install it:

```sh
bash plugins/install.sh
```

Read its `main.swift` as a starting template.
