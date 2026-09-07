# Writing an Overlap suggestion plugin

Overlap has two extension points: **tag suggestions** and **semantic search**
(see [Search plugins](#search-plugins-capabilities-search)). A plugin is a
standalone executable — in **any language** — that Overlap runs to suggest tags
for the selected files (or rank files for a query). Nothing links against the
app; plugins ship and update independently.

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
   them as tap-to-apply chips. A chip applies its tag to **only the files it
   covers** (the paths you suggested it for), so a clustering plugin can return
   several disjoint groups over one selection — each group becomes its own chip
   with a member-count badge. ⌥-click a chip to select just its members in the
   grid before committing.

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
| `capabilities` | optional; `["suggest"]` (default) and/or `["search"]` — see [Search plugins](#search-plugins-capabilities-search) |
| `queryTimeoutMs` | optional, search plugins only: budget for one query (indexing uses `timeoutMs`) |

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

### Settings (optional)

Declare tunables in the manifest and Overlap renders them in **Plugins ▸ Plugin
Settings…** (toggles, sliders, pickers) and injects the merged values into every
request as `settings: {key: value}`:

```json
"settings": [
  { "key": "minConfidence", "type": "number", "label": "Minimum confidence",
    "section": "Tuning", "min": 0, "max": 0.9, "step": 0.05, "default": 0.3,
    "help": "Suggestions below this score are dropped" },
  { "key": "channelFaces", "type": "bool", "label": "Faces", "section": "Channels",
    "default": true }
]
```

`type` is `bool` (toggle), `number` (slider with `min`/`max`/`step`), or `choice`
(picker over `choices: [{value,label}]`). Treat request `settings` as overrides
over your own defaults; ignore unknown keys. A request without `settings` (older
host) must keep working. `overlap-suggest/` is the reference implementation.

### Progress (stderr, optional)

A plugin that does heavy first-run work (embedding a whole library, building an
index) can write **human-readable progress lines to stderr** while it works.
Overlap streams them and shows the latest line in the suggestion bar (e.g.
`Building suggestion index… 300/4000`). One line per update, newline-terminated;
stdout stays reserved for the single JSON response. Emitting nothing is fine —
plugins with no heavy phase just return their JSON. `visionknn` does this only on a
cold/changed library, staying silent on warm cache hits.

---

## Similarity plugins (`wantsLibrary`)

Set `wantsLibrary: true` and Overlap hands you every already-tagged file plus its
tags. The intended pattern: **embed** those files, **cluster** or nearest-
neighbor the target against them, and suggest the tags its closest matches carry.
Cache your embeddings by `path` + `modDate` so you only re-embed what changed.

`plugins/visionknn/` is exactly this, for real: Apple Vision FeaturePrint
embeddings + cosine kNN over the library, with an on-disk embedding cache. It drops
in with **zero app changes**.

---

## Search plugins (`capabilities: ["search"]`)

A second extension point, same process contract: **semantic search**. Declare
`"capabilities": ["search"]` (and `wantsLibrary: true`) and Overlap stops
sending you suggest traffic and instead drives you in two shapes:

| shape | request | expected response |
|---|---|---|
| **index warm-up** | `files: []`, `library: [every image in the corpus]`, no `query` | embed what's new into your own persisted index; `hits: []` |
| **query** | `files: []`, `library: []`, `query: "girl with spiral hair"` | `hits: [{ "path", "score" }]`, best first |

Request/response fields beyond the suggest contract:

```json
// request (additive)
{ "query": "girl with spiral hair" }

// response (additive; `suggestions` may be omitted or empty)
{ "protocolVersion": 1, "suggestions": [],
  "hits": [ { "path": "/Users/me/Pictures/x.jpg", "score": 0.31 } ],
  "indexedCount": 4312 }
```

- The corpus is **every image under the scope and the watched folders, tagged
  or not** (unlike `wantsLibrary` for suggesters, which is tagged files only).
  `LibraryItem.tags` is `[]` for untagged files.
- Hits are **not** path-validated against `files` — returning files the host
  never mentioned is the point. Overlap orders the grid by `score` and, when a
  tag query is active, keeps only hits that pass it.
- `indexedCount` lets the UI say "index not built yet" instead of "no matches".
- Warm-up runs after the suggestion warm-up (chained, never concurrent), when
  the scope or watched folders change, and from Plugins ▸ Rebuild Search Index.
  Progress lines on stderr show in the strip above the grid.
- A query spawns a fresh process, so keep model load cheap or cached; Overlap
  submits on Return, not per keystroke.

`plugins/overlap-clip/` is the reference: MobileCLIP-S2 (Core ML) image + text
encoders, downloaded on first use.

---

## Bundled plugins

| plugin | what it does | library? |
|---|---|---|
| `plugins/overlap-suggest/` | **the shipping suggester** — FeaturePrint kNN + face identities + classifier labels + OCR + face-quality gating + aesthetics, fused (noisy-OR) with co-occurrence rerank/mutex learned from your tags; declares tunables via manifest `settings` (rendered in Plugins ▸ Plugin Settings…) | yes |
| `plugins/overlap-clip/` | **semantic search** (`capabilities: ["search"]`) — MobileCLIP-S2 text→image search over every image in the scope + watched folders; ~200 MB of Core ML models fetched on first use into the plugin cache | yes |
| `plugins/folderkind/` | folder name + file kind + neighbor tags — dependency-free reference/template (not installed by default) | yes |
| `plugins/mockcluster/` | deterministic fake clusters — exercises the group-chip UX with no ML (not installed by default) | no |

(The earlier `visionknn` and `facecluster` plugins were merged into `overlap-suggest`,
which migrates their caches automatically; their dirs are removed.)

Build and install all of them:

```sh
bash plugins/install.sh
```

Read `folderkind/main.swift` as a starting template; `visionknn` and `facecluster`
show the real embed/cluster patterns with Apple Vision.
