# overlap-arena — Are.na for Overlap

A `capabilities: ["source"]` plugin (see [docs/PLUGINS.md](../../docs/PLUGINS.md)).
It speaks Are.na's REST API v3; Overlap itself knows nothing about Are.na.

- **Sign in:** create a personal access token at
  <https://www.are.na/settings/oauth> (write scope to send or edit), paste it in
  *Sources ▸ Connected Services…*. It's kept in the login keychain.
- **Browse:** Feed, Following, My Channels, any channel by link; Search appears for
  Premium/Supporter accounts (Are.na's search endpoint is Premium-only).
- **Import / sync:** whole channels or picked blocks. Images and attachments become
  files; text blocks `.md`, links and embeds `.webloc`. Files land in
  `<library>/Are.na/<Channel>/`, tagged `arena/<Channel>`.
- **Send / publish:** uploads go through Are.na's presigned uploads, one block per
  file (batch create is Premium-only and private-channel-only). Files already on
  Are.na are connected, not re-uploaded.
- **Rate limits:** short waits (≤60 s) are taken in-process; longer ones go back to
  Overlap as `retryAfter`. Sync is always user-triggered — Are.na's terms forbid
  bulk scraping.

Build: `swiftc -O main.swift -o overlap-arena` (or `bash plugins/install.sh`).
