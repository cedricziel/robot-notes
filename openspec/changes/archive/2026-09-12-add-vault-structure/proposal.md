## Why

Every note today is a flat `<ULID>.md` file with no folders, no links between notes, and no tags — the only structure is a single paginated list. Users organizing more than a handful of notes need a real hierarchy and a way to connect notes to each other, the way Obsidian vaults work. All existing clients (REST API, MCP server, Flutter app, realtime sync) already address notes exclusively by stable `id`, never by file path, which makes it safe to change the on-disk layout without breaking any client contract.

## What Changes

- **BREAKING**: note files move from `<data-dir>/content/<id>.md` to `<data-dir>/content/<path>/<Title>.md`; `id` stays in frontmatter as the sole API address but drops out of the filename. A startup migration renames existing files.
- Notes gain a `path` (folder) field; changing `title` renames the file, changing `path` moves it, both under existing `If-Match`/lock rules; colliding target paths return `409 path_conflict`.
- New endpoints: move/rename via `PUT /notes/{id}`, `GET /notes/tree`, a `path` filter on `GET /notes`, `GET /notes/{id}/backlinks`, `GET /notes/{id}/links`. Path/title collisions (including case-only ones) are rejected atomically, not just checked-then-written.
- New inline link syntax `[[Title]]` / `[[Title|Alias]]`, resolved via a title→id index; unresolved ("phantom") links stay valid until a matching title appears; renaming rewrites references across the vault, skipping notes locked by another actor.
- Tags merge frontmatter `tags: [...]` and inline `#tag`/`#parent/child` into one per-note set; new `GET /tags` and a `tag` filter on `GET /notes`.
- Search indexes `path`, `tags`, and link edges, so it can filter by folder/tag and answer "what links here."
- MCP tools gain `path`/`tag` parameters plus new move and get-backlinks tools.
- Flutter sidebar becomes a folder tree; editor gains `[[`-autocomplete and a backlinks panel; UI gains tag chips/filter and a move action.
- Realtime sync gains a `moved` action on the existing `changed` broadcast.

## Capabilities

### New Capabilities

- `links`: inline `[[Title]]` link parsing, title resolution, backlink queries, and rename-propagation across the vault.

### Modified Capabilities

- `notes-storage`: filename is no longer `<id>.md`; adds `path`, atomic case-insensitive move/rename with collision handling, and the legacy-layout migration.
- `notes-api`: preserves existing pagination/sort; adds move/rename, folder-tree listing, path/tag filters. Backlink/link endpoints live in `links`, not here.
- `search`: indexes `path`, `tags`, link edges; rebuild-on-corruption repopulates them.
- `mcp-server`: existing tools gain `path`/`tag` params; adds move and backlinks tools.
- `flutter-client`: navigation moves from flat list to folder-tree, plus links/backlinks/tags UI.
- `realtime-sync`: `changed` broadcast gains a `moved` action.
- `lock-management`: move/rename is a lock-governed write; rename-propagation skips notes locked by another actor.

## Non-goals

- No `[[Title#Heading]]` heading-anchor links (deferred).
- No automatic empty-folder pruning.
- No full resolution of duplicate-title ambiguity across folders (v1 logs a warning and picks the first match by id order).
- No change to authentication, locking mechanics, or realtime transport beyond the one new broadcast action.

## Impact

Server: storage, note CRUD, search indexer, MCP tools, realtime broadcaster. Flutter: navigation shell, editor, search/filter UI. One-time migration on first startup after upgrade. No changes to auth; broadcast wire format only gains the additive `moved` action.
