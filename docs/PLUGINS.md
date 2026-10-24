# Writing an Overlap plugin

Overlap has three extension points:

- **Tag suggestions** — suggest tags for the selected files (the default).
- **Semantic search** — rank files for a text query
  (see [Search plugins](#search-plugins-capabilities-search)).
- **Connected services** — pull files from, and push files to, an external image
  or web service (see [Connected-service plugins](#connected-service-plugins-capabilities-source)).

A plugin is a standalone executable — in **any language** — that Overlap runs as
a child process. Nothing links against the app; plugins ship and update
independently. The Plugins menu groups installed plugins by these three kinds.

Overlap ships three plugins (see [Bundled plugins](#bundled-plugins)). This page
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
| `capabilities` | optional; `["suggest"]` (default) and/or `["search"]`, `["similar"]`, `["duplicates"]` — see [Search plugins](#search-plugins-capabilities-search) |
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

### Find Similar (`"similar"`) and duplicates (`"duplicates"`)

Two more shapes over the same index, each behind its own capability:

| shape | request | expected response |
|---|---|---|
| **similar** | `similarTo: ["/path/a.jpg", …]` | `hits`, best first, without the input files |
| **duplicates** | `duplicates: { "threshold": 0.95, "paths": [...] }` (`paths` omitted = whole index) | `pairs: [{ "a", "b", "score" }]` at or above `threshold` |

- Similar: average the inputs' vectors. A file your index hasn't seen (a
  connected-service preview, say) may be embedded on the spot; don't store it.
- Duplicates: Overlap finds byte-identical copies itself and joins your pairs
  into groups, skipping pairs the user marked "Not Duplicates". Its Strict ↔
  Loose slider sends 0.98 … 0.90.
- Neither is ever sent hidden-tag or vault files.

`plugins/overlap-clip/` is the reference: MobileCLIP-S2 (Core ML) image + text
encoders, downloaded on first use. It has all three capabilities.

---

## Connected-service plugins (`capabilities: ["source"]`)

A connected service is an external image or web service the user keeps
collections on. Overlap stays unaware of which service it is: it only knows
**collections** (a board, an album…) and **items** (a remote thing that becomes a
local file). Every network call, credential and rate limit lives in the plugin.

The process model is the same as above, but the request carries an `op` and the
response fills only that op's fields. The full wire types are in
[`Sources/SourceContract.swift`](../Sources/SourceContract.swift).

### Manifest additions

```json
{
  "capabilities": ["source"],
  "source": {
    "displayName": "My Service",
    "collectionNoun": "board",
    "tagPrefix": "myservice",
    "canPush": true,
    "canCreateCollection": true,
    "canEditCollection": true,
    "visibilities": [
      { "id": "secret", "label": "Secret", "help": "Only you", "audience": 0 },
      { "id": "public", "label": "Public", "help": "Anyone", "audience": 1 }
    ]
  },
  "secrets": [
    { "key": "token", "label": "Access token", "help": "…", "url": "https://…/settings" }
  ]
}
```

- `tagPrefix`: pulled files are tagged `<tagPrefix>/<Collection Title>`, and land in
  `<library>/<displayName>/<Collection Title>/`.
- `visibilities`: the service's own words. `audience` orders them (0 = only the
  owner); the host asks for confirmation whenever a change raises it, and warns
  before sending to any collection with `audience > 0`.
- `secrets`: Overlap stores them in the login keychain and sends each plugin only
  its own, as `request.secrets`. They never go to UserDefaults or `settings`.

### Ops

| `op` | request fields | response fields |
|---|---|---|
| `status` | `secrets` | `account { authenticated, name?, url?, canWrite?, browseScopes? }` |
| `collections` | — | `collections` (the user's own) |
| `resolve` | `collection` = a pasted link, slug or id | `collections: [one]` |
| `pull` | `collection`, `cursor`, `since`, `stagingDir`, `knownIds` | `items`, `nextCursor` |
| `browse` | `scope` (a `browseScopes` id or `"collection"`), `collection`, `query`, `cursor` | `collections`, `items` (with `previewURL`, no downloads), `nextCursor` |
| `fetch` | `remoteIds`, `stagingDir` | `items` (downloaded) |
| `related` | `remoteId` (collections an item is in) or `collection` (its owner's others) | `collections` |
| `push` | `collection`, `items: [{ path, title, remoteId? }]` | `pushed: [{ path, remoteId?, url?, error? }]` |
| `createCollection` | `title`, `visibility`, `description` | `collections: [created]` |
| `updateCollection` | `collection`, `title?`, `visibility?`, `description?` | `collections: [updated]` |

Any op may answer `{ "error": "…" }` (shown to the user) or
`{ "retryAfter": seconds }` (the host waits and calls again — only for idempotent
ops; a half-done `push` should report per-item errors instead).

Rules the host enforces, so plugins don't have to:

- **Downloads** must be written inside `stagingDir`; anything else is ignored. The
  host moves files into the library, never overwriting, and deletes the staging dir.
- **`knownIds`** lists remote ids already on disk: return them in `pull`, but don't
  download them again.
- **Origin** is written on each file as the `com.overlap.origin` extended attribute
  (plus Finder's *Where from*), so re-syncs, cross-collection dedupe and
  connect-instead-of-upload need no index. A `push` item with `remoteId` set is
  already on the service: connect it rather than upload.
- **Privacy**: hidden-tag files, vault files and private boards are filtered out
  before a plugin sees any path, and every push is confirmed by the user.
- **Browse scopes** come from `status`, so a plugin can offer a scope only when the
  account supports it (e.g. a paid-tier search endpoint).
- **Browsing** happens in Overlap's main window: the sidebar lists each service's
  scopes and synced collections, and `browse` results fill the grid. Each item's
  `previewURL` is cached under `~/Library/Caches/Overlap/Remote` (500 MB cap), so
  give it an image big enough for Quick Look (~1200 px). Items without one show as
  text (`text`) or a link (`sourceURL`/`url`).
- **Media**: give video and other embeddable items `embedHTML` (the service's
  iframe) and `sourceURL` (the page). The preview pane plays it. Only the first
  iframe's https `src` is kept, in a sandboxed frame with no stored data.
  Double-click opens `sourceURL`. On `fetch`/`pull`, return the item's picture as
  its `file` so a saved video stays visual. Without a picture it becomes a link
  file.
- **Saving** an item (dragging it onto a tag or a board, or *Save to Library*)
  calls `fetch` for it, and it lands in `<Collection>/` like a pull. A plain save
  always adds the collection tag. When the user drags onto a tag, the collection tag
  is added only if the plugin declares a bool setting `tagSavedWithCollection` and
  the user turns it on.

Start from [`scripts/fixtures/mocksource/main.swift`](../scripts/fixtures/mocksource/main.swift),
a fake service backed by a folder on disk; `scripts/test-sources.swift` runs the
whole pipeline against it headlessly.

---

## Bundled plugins

| plugin | what it does | library? |
|---|---|---|
| `plugins/overlap-suggest/` | **the shipping suggester** — FeaturePrint kNN + face identities + classifier labels + OCR + face-quality gating + aesthetics, fused (noisy-OR) with co-occurrence rerank/mutex learned from your tags; declares tunables via manifest `settings` (rendered in Plugins ▸ Plugin Settings…) | yes |
| `plugins/overlap-clip/` | **semantic search** (`capabilities: ["search"]`) — MobileCLIP-S2 text→image search over every image in the scope + watched folders; ~200 MB of Core ML models fetched on first use into the plugin cache | yes |
| `plugins/overlap-arena/` | **connected service** (`capabilities: ["source"]`) — Are.na: browse, import and sync channels, send files, create and publish channels | no |

(The earlier `visionknn` and `facecluster` plugins were merged into `overlap-suggest`,
which migrates their caches automatically; their dirs are removed.)

Build and install all of them:

```sh
bash plugins/install.sh
```

Read `overlap-suggest/main.swift` for the Apple Vision embed/cluster patterns,
`overlap-clip` for a search plugin, and `overlap-arena` for a connected service.
