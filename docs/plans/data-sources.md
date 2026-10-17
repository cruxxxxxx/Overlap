# Data-source plugins + Are.na sync — plan

Status: phases 1–5 built 2026-10-17 (uncommitted). Headless test: `scripts/test-sources.swift`.
Built beyond the original plan: `resolve` op (paste a channel link), `knownIds` on pull (the
plugin skips downloads for items already local), text → `.md` and link/embed → `.webloc`.
Are.na's batch-create endpoint is Premium-only and private-channels-only, so push makes one
`POST /v3/blocks` per file.

## Goal

Let Overlap pull files in from, and push files out to, external services through a
plugin. The host knows nothing about any one service. Are.na is the first provider;
Pinterest and others should fit the same contract later.

## Principles

- **Host is agnostic.** It deals in *collections* (channel, board, album) and *items*
  (a remote thing that becomes a local file). Every network call, auth detail and
  rate limit lives in the plugin.
- **Same process model as today.** Child executable, JSON request on stdin, JSON
  response on stdout, stderr lines as progress, timeout kill. New capability
  `"source"` next to `"suggest"` and `"search"`.
- **Files stay real files.** Pulled items are ordinary files in a normal folder, tagged
  with Finder tags. Nothing is locked in a private store.
- **No new index.** Which remote item a file came from is written *on the file*
  (extended attribute). Incremental sync scans the destination folder on demand.
- **Privacy is enforced by the host, not the plugin.** Hidden-tag files, vault files and
  private boards never reach a source plugin. Pushing always asks first.

## 1. Contract (`capabilities: ["source"]`)

One request type with an `op`; the plugin answers per op.

```jsonc
// host → plugin
{
  "protocolVersion": 1,
  "op": "status" | "collections" | "pull" | "push" | "createCollection",
  "settings": { ... },              // manifest settings, as today
  "secrets":  { "token": "…" },     // from the keychain; only this plugin's keys
  "stagingDir": "/…/Overlap/Staging/<run>",   // pull: plugin writes downloads here
  "collection": "channel-slug-or-id",         // pull / push
  "cursor": "opaque", "since": "ISO-8601",    // pull paging / incremental
  "items": [ {                                  // push
    "path": "/…/a.jpg", "title": "a", "tags": ["x"],
    "remoteId": "123" | null                    // already exists remotely → connect, don't re-upload
  } ],
  "title": "New channel", "visibility": "private"  // createCollection
}

// plugin → host
{
  "protocolVersion": 1,
  "account":     { "name": "…", "url": "…", "authenticated": true },        // status
  "collections": [ { "id", "title", "url", "count", "updatedAt",
                     "writable": true, "visibility": "public|closed|private" } ],
  "items": [ {                                                               // pull
     "remoteId": "123", "kind": "image|file|text|link|embed",
     "title", "description", "url" /* remote page */, "sourceURL" /* original */,
     "file": "<path inside stagingDir>" | null,   // downloaded bytes, if any
     "text": "…" | null,                           // text blocks
     "updatedAt", "labels": ["…"]                  // provider tags, passed through
  } ],
  "nextCursor": "opaque" | null,
  "pushed": [ { "path", "remoteId", "url", "error": null } ],                // push
  "retryAfter": 42,                                 // rate-limited: host waits, re-calls
  "error": "human-readable" | null
}
```

Manifest additions (all optional so existing manifests keep decoding):

```jsonc
"capabilities": ["source"],
"source": { "displayName": "Are.na", "collectionNoun": "channel",
            "tagPrefix": "arena", "canPush": true, "canCreateCollection": true },
"secrets": [ { "key": "token", "label": "Personal access token",
               "help": "Create one with write scope", "url": "https://www.are.na/settings/oauth" } ]
```

Host changes:
- `PluginContract.swift`: `SourceRequest`, `SourceResponse`, manifest fields above.
- `SuggestionEngine.runProcess` becomes generic over `Encodable` request / `Decodable`
  response so suggest, search and source share it.
- New `SourceEngine.swift`: runs one op; loops `pull` over `nextCursor`; honors
  `retryAfter`; cancellable.
- Secrets: keychain service `com.mike.overlap.sources`, account `<pluginID>.<key>`.
  Never in `pluginSettings` / UserDefaults. Settings UI gets an *Accounts* section
  rendered from `secrets`.
- `plugins/mocksource`: a fake provider reading a local JSON fixture, so the host
  side is testable headless with no network (see `scripts/fixtures/mocksource`).

## 2. File origin (no index)

On every pulled or pushed file, write xattr `com.overlap.origin`:

```json
{ "plugin": "com.overlap.arena", "remoteId": "123", "collection": "my-channel",
  "url": "https://www.are.na/block/123", "updatedAt": "…" }
```

(an array if the same file belongs to several collections). Also set
`com.apple.metadata:kMDItemWhereFroms` to the item's URL so Finder's *Where from*
shows it. xattrs survive moves, renames and the vault. Incremental pull = read the
xattrs of files in the link's destination folder, skip known `remoteId`s.

## 3. Pull (import)

- *File ▸ Import from Are.na…* (menu built from discovered source plugins): pick a
  collection, then a destination folder (default `~/Pictures/<displayName>/<collection>`).
- Plugin downloads into `stagingDir`; host moves files into the destination (never
  overwrites; "name 2.jpg"), writes the origin xattr, and tags each file
  `<tagPrefix>/<collection title>`. Provider labels become tags only if a setting says so.
- Kinds: image / file → the file itself. Text → `.md`. Link / embed → `.webloc`, plus
  its cover image when the plugin provides one. (Text/link can come in a later phase.)
- Remote deletions never delete local files. The file just stops being refreshed.
- The link is remembered (`Sources/links.json`: plugin, collection, destination,
  cursor, lastSync), so *Sync now* repeats it incrementally.

### Where pulled files live

- Default destination: `<library scope>/<displayName>/<Collection Title>/`, e.g.
  `~/Pictures/Are.na/Moodboard Refs/`. Always inside the scope so the catalog sees it.
  The import sheet can override it; the choice is saved on the link.
- Downloads go to `~/Library/Application Support/Overlap/Staging/<run>/` first and the
  host deletes that after every run, so partial downloads never reach the library.
- The folder is just storage; the tag is the identity. Moving files within the scope
  keeps the tag and origin xattr, so sync still recognises them.
- A block in two pulled channels becomes one file with both tags (origin xattr is an
  array). It stays in the first channel's folder. Duplicate check = origin xattrs of
  files under `<scope>/<displayName>/` plus the link's own destination.
- The `<displayName>` folder is not made a watched folder: files arrive tagged.

## 4. Push (export)

- *Send to Are.na…* from a selection, the current results, or a board.
- Collection picker (from `collections`) + *New channel…* (`createCollection`).
- Host gate before the plugin sees anything: drop hidden / vault / private-board items
  using the same filter the suggest plugins use. If anything was dropped, say how many.
- Confirm sheet: N files → channel X (visibility shown, e.g. "public"). Outward-facing,
  so always confirmed.
- Files that already carry an origin xattr for this plugin are *connected* by
  `remoteId`, not uploaded again. The new `remoteId` is written back to the xattr.

## 5. Board ↔ collection link

- A board can link to one collection: `MoodBoard.sourceLink { plugin, collection, direction }`.
- *Refresh* on a linked board pulls new remote items (reusing the board's existing
  refresh + `dismissed` logic) and, if two-way, pushes new board items.
- Text blocks ↔ board note elements is a later phase.
- Private boards cannot be linked.

## 6. Are.na plugin (`plugins/overlap-arena`, Swift + URLSession)

API v3 (`https://api.are.na/v3`, OpenAPI at `/v3/openapi`):
- Auth: `Authorization: Bearer <personal access token>`; needs `write` scope to push.
  OAuth2 + PKCE is supported by Are.na. It's a later option, needing a redirect handler in the host.
- `status` → `GET /v3/me`. `collections` → the user's channels (`GET /v3/users/{id}/contents`
  or the channels endpoints). `pull` → `GET /v3/channels/{id}/contents` paged; images
  are fetched from their CDN URLs.
- `push` → `POST /v3/uploads/presign` (≤50 files per call) → `PUT` bytes to the S3 URLs
  → `POST /v3/blocks/batch` with `value` = the uploaded URL, `title`, optional
  `description`, connected to the channel. An existing block → `POST /v3/connections`.
- Rate limits: per account per minute (free 120, premium 300, supporter 600); writes
  also have an hourly budget. Read `X-RateLimit-Remaining` / `X-RateLimit-Reset`; on
  429 return `retryAfter`. Are.na's terms forbid bulk scraping, so sync is user-
  triggered for the user's own / followed channels. No background crawling.

## 7. Phases

1. Contract + generic runner + keychain secrets + Accounts UI + `mocksource`. Headless test.
2. Are.na plugin: `status`, `collections`, `pull` (images + attachments).
3. Host pull: import sheet, staging → destination, xattrs, tags, saved links, *Sync now*.
4. Push: *Send to…*, privacy gate, confirm, batch upload, xattr write-back.
5. Board links (pull + optional push on refresh).
6. Later: text/link blocks, OAuth PKCE, a remote browse/search panel, more providers.

## Round 2 (built 2026-10-17)

- **Ops** `updateCollection`, `browse` (scopes chosen per account by the plugin in `status`),
  `fetch` (download picked ids), `related` (collections an item is in / owner's others).
- **Edit collection**: rename (renames the local tag too), description, visibility.
  Raising visibility always confirms.
- **Browse window** (`SourceBrowserView`): Feed, Following, My Channels, Search (Are.na Premium
  only, so the plugin only offers it on premium/supporter tiers), any channel by link. Previews
  load from the service's image URLs; nothing downloads until *Save*. Picks are filed under
  the channel they were seen in (or `Saved`), get that channel's tag, and can go straight onto a board.
- **Publish board**: create the collection, link the board, send its files.
- Not built: CLIP "more like this" over remote previews (needs image→image in overlap-clip).

## Other providers (feasibility notes)

- **Pinterest**: API v5, OAuth only, app needs Pinterest review for write scopes. Boards
  map cleanly to collections, pins to items.
- **Instagram**: the personal-account Basic Display API was retired (Dec 2024). Only the
  Graph API for business/creator accounts remains, so pull-own-media at most.
- **Local / self-hosted** (a folder of JSON, a static site, Raindrop, Cosmos if it opens an
  API): same contract, no host changes.

## Decisions (2026-10-17)

- Pull lands straight in the library, already tagged. No Queue step.
- Channel tag shape: `arena/<Channel Title>` (that is, `<tagPrefix>/<collection title>`).
- On push, Overlap tags stay local. Nothing goes in the block's description or metadata.
- Sync runs on *Sync now* and when a linked board refreshes. No background timer.
