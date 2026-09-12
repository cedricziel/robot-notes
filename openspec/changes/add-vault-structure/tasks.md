## Phase 1 — Storage: path, move/rename, migration

### 1. Frontmatter and path plumbing

- [x] 1.1 ~~Write failing tests in `server/test/src/frontmatter_test.dart`~~ — N/A: `frontmatter.dart` is a generic YAML round-trip parser with no typed fields (see deviation note); `path` is added to the typed model in `storage.dart` instead (task group 2)
- [x] 1.2 ~~Add `path` to the frontmatter model~~ — N/A, see 1.1
- [x] 1.3 Write failing tests for a filename-sanitizer (strip `\ / : * ? " < > |` from a title/path segment) and for NFC normalization (an NFD-decomposed input title normalizes to NFC before sanitizing) — `server/test/src/note_path_test.dart`
- [x] 1.4 Implement the sanitizer and normalizer (new small function/file next to `storage.dart`) — `server/lib/src/note_path.dart`, using the `unorm_dart` package (added to `server/pubspec.yaml`) for real NFC normalization, since Dart's SDK has no built-in Unicode normalization; run tests green
- [x] 1.5 Commit: `feat(server): add path field and filename sanitizer for vault layout`

### 2. Write path to `<path>/<Title>.md`

- [x] 2.1 Write failing tests in `server/test/src/storage_test.dart` asserting a new note is written at `<data-dir>/content/<path>/<sanitized-title>.md` instead of `<id>.md`, for both root and nested paths
- [x] 2.2 Update `server/lib/src/storage.dart` write path to compute the target path from `path`+`title` instead of `id`; run tests green
- [x] 2.3 Write failing test: startup index scan (`meta_index.dart`) recursively walks `content/**/*.md` and keys by frontmatter `id` — implemented as `Storage._scanAll()` (id→relative-path cache, since `id` no longer determines the file location) rather than in `meta_index.dart` itself, which continues to key off whatever `Storage.list()` reports
- [x] 2.4 ~~Update `server/lib/src/meta_index.dart` to scan recursively~~ — see 2.3; `meta_index.dart` gains `path` on `NoteSummary` and a `pathPrefix` filter on `page()` (pulled forward from task group 5, since it's the same edit)
- [x] 2.5 Commit — folded into the task-group-3 commit below (`storage.dart` rewrite is one inseparable diff covering both write-path and rename/move); see that commit's body

### 3. Rename/move on write + atomic, case-insensitive collision handling

- [x] 3.1 Write failing tests: changing `title` renames the file in place; changing `path` moves it; both bump `version` via the existing tmp+fsync+rename path
- [x] 3.2 Implement rename/move in `server/lib/src/storage.dart` directly (not `note_write_service.dart` — that layer only orchestrates search/meta/broadcast side effects around `Storage`, which is where the file-location logic already lived); run tests green
- [x] 3.3 Write failing test: a title/path change whose target path already belongs to a different note (exact match, and case-only match, e.g. `Ideas` vs `ideas`) leaves both files untouched and surfaces a distinguishable conflict result
- [x] 3.4 Implement the collision check comparing NFC-normalized, lowercased target paths against an id↔path cache in `Storage`, returning `PathConflictException`; run tests green
- [x] 3.5 Write a failing test: two concurrent renames/moves that resolve to the same target path — exactly one succeeds, the other gets `PathConflict`, and neither note's file is lost or overwritten
- [x] 3.6 Implement per-target-path serialization for the check-then-write sequence (a lock keyed by the normalized target path, alongside the existing per-note-id write serialization); run the concurrency test green
- [x] 3.7 Write failing test: moving a note out of a folder does not delete the now-empty folder
- [x] 3.8 Asserted with a `Directory.existsSync()` test — true by construction, no fix needed
- [x] 3.9 Commit: `feat(server): store, move, and rename notes under folder/title paths` (covers task groups 2 and 3 together — see 2.5)

### 4. Legacy layout migration

- [x] 4.1 Write failing tests in a new `server/test/src/legacy_migration_test.dart`: a `<ulid>.md` file with no `path` key is renamed to `<Title>.md` at root with `path: ""` added; a file that already has `path` is untouched; colliding titles among migrating files get ` (2)`, ` (3)` suffixes; a legacy file whose natural title collides with an already-existing non-legacy note (e.g. `Ideas (2)` already exists) is not overwritten — de-dup checks the full target namespace, not just other migrating files; files are processed in ascending-id order; a single bad file is logged and skipped without failing the migration
- [x] 4.2 Implement the migration as a startup step that runs before `meta_index` build (`server/lib/src/legacy_migration.dart`), reusing `note_path.dart`'s sanitizer/normalizer/collision-key
- [x] 4.3 Wire the migration into server startup (`app_deps.dart`, before `Storage`/`MetaIndex` are constructed); run tests green
- [x] 4.4 Commit: `feat(server): migrate legacy <id>.md files to vault-style paths on startup`

### 5. API: move/rename, tree, path filter — preserving existing sort/pagination

- [x] 5.1 Write failing route tests: `PUT /notes/{id}` accepts `path` and returns the moved note; a collision (including case-only) returns `409 {"error":"path_conflict"}`
- [x] 5.2 Update `server/routes/notes/[id]/index.dart` to accept `path` and map `PathConflictException` to 409; run tests green
- [x] 5.3 Write failing route tests: `GET /notes` accepts `path` (prefix filter), returns matching items only, and the existing `sort=updated_desc`/`after` behavior is unaffected and composes correctly with `path` — `tag` deferred to task group 11, where tag data first exists (there is nothing to filter by yet in Phase 1)
- [x] 5.4 Implement the `path` filter on the list handler as an additional pre-filter applied before existing sort/pagination, not a replacement of it (see `MetaIndex.page`'s `pathPrefix` param); run tests green including the pre-existing sort tests
- [x] 5.5 Write failing route tests: `GET /notes/tree` returns `{folders: [{path, note_count}]}` for folders that directly contain at least one note (intermediate folders with no direct notes are omitted)
- [x] 5.6 Implement `server/routes/notes/tree.dart` reading from the meta index; run tests green
- [x] 5.7 Commit: `feat(server): expose move, path filter, and folder tree endpoints` (`tag` filter tracked under task group 11)

### 6. Realtime: `moved` action

- [x] 6.1 Write failing test: a path-changing `PUT` broadcasts `changed` with `action: "moved"`
- [x] 6.2 Add `ChangeAction.moved` to `shared/lib/src/ws.dart` and pick it in `NoteWriteService.update` when the resolved path differs from the note's prior path (compared via a pre-lock read, which is race-safe here since any real interleaving would also fail the caller's own `ifMatch` check — see commit body for the full argument); run tests green. Also required a one-line compile fix in `app/lib/src/notes/notes_list_controller.dart`'s exhaustive `switch (ChangeAction)` (treats `moved` like `updated` for now; richer folder-tree-aware handling is task group 14)
- [x] 6.3 Commit — folded into the task-group-5 commit above, since the route test asserting `action: "moved"` and the enum/service change landed together

## Phase 2 — Links and backlinks

### 7. Link parsing and title index

- [x] 7.1 Write failing tests for a link parser: extracts `[[Title]]` and `[[Title|Alias]]` occurrences from markdown content, leaving the raw text untouched — `server/test/src/links_test.dart`; also covers `rewriteLinks` (needed by task group 8) since it lives in the same pure module
- [x] 7.2 Implement the parser (new `server/lib/src/links.dart`); run tests green — also implements `rewriteLinks` (span-preserving rewrite used by rename propagation, task 8) alongside `parseLinks`, since both are pure text functions over the same `ParsedLink` shape
- [x] 7.3 Write failing tests: a title→id resolution index resolves an existing title, treats a non-matching title as unresolved, and is rebuilt on startup — added to `server/test/src/meta_index_test.dart`
- [x] 7.4 Implement the title index alongside `meta_index.dart` (or as a new small companion module); run tests green — implemented as `MetaIndex._byTitle` + `MetaIndex.resolveTitle()`, kept in sync by `scan`/`upsert`/`remove`
- [x] 7.5 Commit: `feat(server): parse [[wikilinks]] and resolve titles to ids`

### 8. Rename propagation

- [x] 8.1 Write failing tests: renaming note A rewrites `[[OldTitle]]` and `[[OldTitle|Alias]]` to the new title (alias preserved) in every note that references it, incrementing their versions — `server/test/src/note_write_service_rename_propagation_test.dart`
- [x] 8.2 ~~Implement propagation in `note_write_service.dart`'s rename path, using the title index to find referencing notes~~ — uses a new companion `server/lib/src/link_index.dart` (`LinkIndex.sourcesLinkingToTitle`) rather than `MetaIndex`'s title index directly: finding "who links to title X" needs a title→*sources* reverse lookup, which is a different structure from `MetaIndex`'s title→id resolution index from task group 7 (also reused by task group 9's backlinks); run tests green
- [x] 8.3 Write failing test: a referencing note currently locked by another actor is skipped, with a logged warning, and NOT rewritten — same test file
- [x] 8.4 Implement the lock check before each propagated rewrite using `lock_manager.dart`; run tests green
- [x] 8.5 Write failing test: each propagated rewrite broadcasts its own `changed`/`updated` event — same test file
- [x] 8.6 Wire the broadcast call into the propagation loop; run tests green — each propagated rewrite goes through `NoteWriteService.update` itself, so it gets the standard broadcast for free
- [x] 8.7 Commit: `feat(server): propagate note renames to referencing links`

### 9. Backlinks and links endpoints

- [x] 9.1 Write failing route tests: `GET /notes/{id}/backlinks` returns notes linking to `{id}`; `GET /notes/{id}/links` returns outgoing links with `resolved`/`id`; unknown id returns 404 — `server/test/routes/notes/[id]/backlinks_test.dart`, `server/test/routes/notes/[id]/links_test.dart`
- [x] 9.2 Implement both routes under `server/routes/notes/[id]/` backed by the title index / link-edges data — `backlinks.dart` and `links.dart`, using `MetaIndex.resolveTitle` + `LinkIndex`; run tests green
- [x] 9.3 Write failing test: a phantom link becomes resolved once the target title is created, without re-saving the linking note — in `links_test.dart`
- [x] 9.4 ~~Implement phantom-link re-resolution as a lookup at query time... or as an index update on create — pick whichever `search_index.dart`'s existing update hooks make simplest~~ — no extra work needed: `GET /notes/{id}/links` already calls `MetaIndex.resolveTitle(edge.targetTitle)` fresh on every request (task 9.2), so a title created after the link was parsed resolves on the very next query for free; run tests green
- [x] 9.5 Commit: `feat(server): expose backlinks and outgoing links endpoints`

## Phase 3 — Tags

### 10. Tag computation

- [x] 10.1 Write failing tests: computed tag set merges frontmatter `tags: [...]` and inline `#tag`/`#parent/child` tokens, de-duplicated, case-insensitive matching with first-seen casing displayed — `server/test/src/tags_test.dart`; also added a `Storage.list computes tags` case to `server/test/src/storage_test.dart` covering the end-to-end wiring (see 10.2)
- [x] 10.2 Implement tag computation as a new module `server/lib/src/tags.dart` (`computeTags()` plus an `aggregateTagCounts()` helper used by task 11's `GET /tags`), not an addition to `links.dart` — tags and links are unrelated pure computations over the same note shape, and keeping them in separate files matches the one-concern-per-module pattern `note_path.dart`/`links.dart` already establish. ~~Where to store the computed set for querying~~ — no separate index class: `NoteSummary` (and thus `MetaIndex`, which already tracks `path` the same way) gains a `tags` field, computed by `StoredNote.toSummary()` via `computeTags(extra: extra, content: content)`. Since every write path already calls `toSummary()` on create/update (`NoteWriteService`) and on startup scan (`Storage.list` → `MetaIndex.scan`), tags are recalculated on every write and startup rebuild for free, with no new wiring needed in `note_write_service.dart` or `app_deps.dart` — the existing `path`-lifecycle precedent already satisfies the "kept live via scan/upsert/remove" requirement; run tests green
- [x] 10.3 Commit: `feat(server): compute merged tag set from frontmatter and inline tags`

### 11. Tag API surface

- [x] 11.1 Write failing route tests: `GET /tags` returns `{items: [{tag, count}]}` sorted by descending count — `server/test/routes/tags_test.dart`; also added a `MetaIndex.page tag filter` group to `server/test/src/meta_index_test.dart` covering the new `tag` param on `page()` directly (mirroring the existing `pathPrefix filter` group), since 11.3's route test alone wouldn't exercise pagination/sort composition the way the `path` filter's own `MetaIndex`-level tests do
- [x] 11.2 Implement `server/routes/tags.dart`, iterating `MetaIndex.all` and aggregating via `tags.dart`'s `aggregateTagCounts()` — the same "compute on demand from the always-current index" idiom `notes/tree.dart` already uses for folder counts, rather than a cached/persisted count table; run tests green
- [x] 11.3 Write failing route tests: `GET /notes?tag=x` filters to notes carrying that tag — added to the existing `group('GET /notes', ...)` in `server/test/routes/notes/index_test.dart`, alongside a case composing `tag` with `path`
- [x] 11.4 Implement the `tag` filter on the notes list handler (`server/routes/notes/index.dart` reads `query['tag']` and passes it to `MetaIndex.page(tag: ...)`, which pre-filters case-insensitively against `NoteSummary.tags` exactly like `pathPrefix` pre-filters against `path` — see task 10's note on where `tags` lives); run tests green
- [x] 11.5 Commit: `feat(server): expose tag listing and tag filtering`

## Phase 4 — Search, MCP, realtime, and client catch-up

### 12. Search index: path, tags, link edges

- [x] 12.1 Write failing tests: `search.db` schema gains `path`, tags, and a link-edges table; writes populate them; deletes clean them up — `server/test/src/search_index_test.dart`
- [x] 12.2 Update `server/lib/src/search_index.dart` schema and write/delete paths; run tests green — `notes_fts` gains `path`/`tags` `UNINDEXED` columns and a new `link_edges` table; `upsert`/`delete` wrap the FTS row plus its `link_edges` rows in one transaction (`_upsertNoTx` factored out so the startup `_rebuild` — which wraps every note in one outer transaction — doesn't nest `BEGIN`s)
- [x] 12.3 Write failing test: an old-schema `search.db` (missing the new tables) is detected as mismatched and triggers a full rebuild — same file, hand-builds a pre-change-shaped db (schema_version 2, no path/tags/link_edges)
- [x] 12.4 Update the schema-check logic; run tests green — `kSearchSchemaVersion` bumped 2 → 3, so any pre-change db (stamped 2) is already "mismatched" by the existing version-comparison check; no separate structural check needed
- [x] 12.5 Write failing route tests: `GET /search` accepts `path` and `tag` filters in addition to `q` — `server/test/routes/search_test.dart`
- [x] 12.6 Implement the filters in the search route; run tests green — `routes/search.dart` passes `path`/`tag` query params through to `SearchIndex.search`, which filters via `substr`/`instr` (not `LIKE`, to avoid `%`/`_` in a folder or tag name being treated as a wildcard)
- [x] 12.7 Commit: `feat(server): index path, tags, and link edges in search`

### 13. MCP tool catalog

- [x] 13.1 Write failing tests: `tools/list` includes `path`/`tag` params on `list_notes`/`create_note`/`search_notes`, plus new `move_note` and `get_backlinks` tools with correct required fields — `server/test/src/mcp/tools_test.dart`, plus updating the pre-existing hard-coded catalog-size assertions (7 → 9) in `server/test/src/mcp/mcp_handler_test.dart` and `server/test/integration/mcp_flow_test.dart` — the delta spec's "tools/list" requirement also adds `path` to `update_note`'s optional properties (not called out in the task text, but explicit in `specs/mcp-server/spec.md`'s MODIFIED catalog line and its "Write tools" requirement: "a `path` change SHALL move the note as in `PUT /notes/{id}`"), so that schema/test coverage is included here too
- [x] 13.2 Update `server/lib/src/mcp/tools.dart` schema definitions; run tests green
- [x] 13.3 Write failing tests: `move_note` performs the same version/lock/path-conflict checks as `update_note` and broadcasts `moved`; `get_backlinks` mirrors the HTTP endpoint including `not_found` — same file; also covers `create_note`/`update_note` gaining `path_conflict` handling (the delta spec requires it for all three path-changing tools, and neither existing tool caught `PathConflictException` before this change)
- [x] 13.4 ~~Implement both tool handlers in `mcp/mcp_handler.dart`~~ — implemented in `mcp/tools.dart` alongside the other seven tool definitions/handlers, matching where every existing tool (including its handler closure) already lives; `mcp_handler.dart` only dispatches `tools/call` to the registry and needed no change. `move_note` delegates to `NoteWriteService.update` (the same underlying call `update_note`/`PUT /notes/{id}` use) rather than reimplementing version/lock/path-conflict handling. `get_backlinks` calls a new shared `computeBacklinks()` (`server/lib/src/backlinks.dart`), extracted from `routes/notes/[id]/backlinks.dart`'s previously-inline logic so the HTTP route and the MCP tool share one implementation instead of two hand-kept-in-sync copies; the route's own tests (`server/test/routes/notes/[id]/backlinks_test.dart`) were re-run unmodified to confirm the refactor preserves behavior; run tests green
- [x] 13.5 Write failing test: existing `list_notes`/`create_note`/`search_notes` handlers accept and apply `path`/`tag` — same file; `list_notes`/`search_notes` items also gain a `path` field per the delta spec's "Read tools mirror the HTTP API" requirement, via a shared `_summaryJson`/`_noteJson` change that also adds `path` to `get_note`/`create_note`/`update_note`/`move_note`'s full-note responses
- [x] 13.6 Wire the new params through; run tests green
- [x] 13.7 Commit: `feat(server): add path/tag params and move/backlinks tools to MCP`

### 14. Flutter: folder tree sidebar

- [x] 14.1 Write a failing widget test: sidebar renders folders from a fake `GET /notes/tree` response as an expandable tree with note counts — `app/test/src/notes/folder_tree_sidebar_test.dart`; also added `app/test/src/notes/folder_tree_controller_test.dart` covering `buildFolderTree`'s nesting logic and the controller's `refresh()`, since the sidebar widget test alone wouldn't exercise the pure tree-building function directly
- [x] 14.2 Implement the sidebar widget and its data source in `app/lib` — `app/lib/src/notes/folder_tree_controller.dart` (`FolderTreeController`, `FolderTreeState`, `buildFolderTree`) and `app/lib/src/notes/folder_tree_sidebar.dart` (`FolderTreeSidebar`, `ExpansionTile`-based); the root folder (`path: ""`) is surfaced separately as `FolderTreeState.rootNoteCount` rather than as a tree node, since it has no segment name of its own to render; run tests green. ~~Committed as part of 14.7~~ — the `RobotNotesClient` groundwork this (and tasks 15/16) build on (`getTree()`, `getBacklinks()`, `path`/`tag` on `listNotes`, `path` on `updateNote`, `PathConflictException`, plus `path`/`tags` fields on the shared `Note`/`NoteMeta` DTOs) was added and tested in one pass across all four Flutter task groups and committed separately as `feat(app): add vault-aware API client methods and DTO fields` before this group's commit, rather than split apart by which later task group first calls each method
- [x] 14.2b Precondition groundwork commit: `feat(app): add vault-aware API client methods and DTO fields` (see note on 14.2) — `shared/lib/src/dtos.dart` + `shared/test/dtos_test.dart` (path on `NoteMeta`/`Note`, tags on `Note`), `app/lib/src/api/api_client.dart` + `app/lib/src/api/api_exceptions.dart` (`getTree`, `getBacklinks`, `path`/`tag` params, `PathConflictException`) + `app/test/src/api/api_client_test.dart`
- [x] 14.3 Write a failing test: selecting a folder scopes the notes list request to `path=<folder>` — added `selectFolder`/`selectTag` cases to `app/test/src/notes/notes_list_controller_test.dart` (controller-level, since that's where the request is actually built) plus a sidebar-level test asserting the tap callback fires with the right path
- [x] 14.4 Wire folder selection into the notes list view model — `NotesListController` gains `selectedPath`/`selectedTag` state and `selectFolder()`/`selectTag()` methods that scope every subsequent `listNotes` call; `app_router.dart`'s `_buildListPage` wires `FolderTreeSidebar.onSelect` to `session.list.selectFolder`; run tests green
- [x] 14.5 Write a failing test: a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` triggers a tree re-fetch — `FolderTreeController` tests, parameterized over the three actions, plus a negative case for `updated`
- [x] 14.6 Wire the WS listener; run tests green — also extended the MODIFIED "moved event updates or removes an entry based on the current folder" scenario: `NotesListController` now re-fetches (rather than upserting in place) on a `moved` event while `selectedPath` is set, since the WS event doesn't carry the note's new path to check client-side
- [x] 14.7 Commit: `feat(app): add folder tree sidebar for vault navigation`

### 15. Flutter: move note action

- [x] 15.1 Write a failing test: the move action sends `PUT /notes/{id}` with the chosen `path` and current `If-Match` — `app/test/src/notes/note_controller_test.dart`'s new `move` group, plus a `note_screen_test.dart` case driving it through the menu/dialog
- [x] 15.2 Implement the move UI entry point and request; run tests green — `NoteController.move()` (new `NoteMode.moving`) and a "Move to folder…" entry in the note view's overflow menu opening a dialog with a **free-text folder path field** (pre-filled with the note's current `path`), not a full `GET /notes/tree` picker — the spec explicitly allows either, and free text needed no new tree-fetching UI plumbing inside the note view; `app/lib/src/notes/note_controller.dart`, `app/lib/src/notes/note_screen.dart`
- [x] 15.3 Write a failing test: a `409 path_conflict` response shows a non-destructive error and leaves the note open — same two files' `move`/`409` cases; also covers a `423` case for lock-conflict handling
- [x] 15.4 Implement the error handling path reusing the existing conflict-UX pattern; run tests green — `409` shows a `SnackBar` naming the path the client itself just tried (the server's `path_conflict` body carries no path to echo back — see the API-groundwork commit's `PathConflictException`); `423` reuses the note view's existing "`<holder>` is editing this note" banner (via `NoteState.lock`) with no separate snackbar, exactly like a `423` on save
- [x] 15.5 Commit: `feat(app): move a note to another folder from the note view`

### 16. Flutter: link autocomplete and backlinks panel

- [x] 16.1 Write a failing test: typing `[[` opens an autocomplete list filtered by subsequent characters against known titles — pure-function tests for the trigger detector in `app/test/src/notes/link_autocomplete_test.dart`, plus a `note_screen_test.dart` case driving it through the real content field
- [x] 16.2 Implement the autocomplete trigger and title lookup (via `GET /search` or `GET /notes`) — `app/lib/src/notes/link_autocomplete.dart` (`detectLinkTrigger`, `LinkAutocompleteController`, debounced like `NotesSearchController`) plus `NoteController.searchLinkTitles()` (delegates to `GET /search`, matching this codebase's rule that all HTTP goes through the note's controller); the suggestion list renders inline below the content field rather than in a floating overlay (`CompositedTransformTarget`/`OverlayEntry`), which needed no cursor-position-tracking plumbing and is simpler to test; run tests green
- [x] 16.3 Write a failing test: selecting an autocomplete entry inserts `[[Title]]` (or `[[Title|Alias]]`) at the cursor — same two files' insertion cases, including one preserving a typed `|alias`
- [x] 16.4 Implement the insertion — pure `insertLink()` in `link_autocomplete.dart`, wired via `_NoteScreenState._insertLink()`; run tests green
- [x] 16.5 Write a failing test: the note view's backlinks panel lists entries from `GET /notes/{id}/backlinks`, with an empty state when there are none — `note_controller_test.dart`'s new `backlinks` group plus `note_screen_test.dart`'s `backlinks panel` group (list, empty state, tap-to-open)
- [x] 16.6 Implement the backlinks panel — `NoteController` loads backlinks alongside `open()` (best-effort: any failure also renders the empty state, since the two are indistinguishable to the user) and exposes them via `NoteState.backlinks`; `_BacklinksPanel` in `note_screen.dart`, shown below the read-only body (not while editing, to keep the editor uncluttered); tapping an entry calls the new `NoteScreen.onOpenNote`, wired in `app_router.dart` to push `/notes/{id}`; run tests green
- [x] 16.7 Commit: `feat(app): add link autocomplete and a backlinks panel to the editor`

### 17. Flutter: tags UI

- [x] 17.1 Write a failing test: the note view renders tag chips from the note's computed tags — `note_screen_test.dart`'s new `tags` group
- [x] 17.2 Implement the chip row; run tests green — `_TagChips` in `note_screen.dart`, a `Wrap` of `ActionChip`s below the read-only body (`note.tags`, now populated per the API-groundwork commit's `Note.tags` field), rendered only in viewing mode and only when non-empty
- [x] 17.3 Write a failing test: tapping a tag chip filters the notes list via `GET /notes?tag=<tag>` — same group's tap case, asserting `NoteScreen.onTagTap` fires with the tag (the `GET /notes?tag=` request itself is `NotesListController.selectTag`'s concern, already covered by task group 14's controller tests, which this reuses rather than re-testing the HTTP call from the note view). ~~a tag browser backed by `GET /tags`~~ — not built: tapping a chip already satisfies the requirement's "e.g. tapping a chip, or a tag browser" either/or, and needed no new screen
- [x] 17.4 Implement the tap-to-filter behavior — `NoteScreen.onTagTap`, wired in `app_router.dart` to `session.list.selectTag(tag)` followed by `context.go('/')` (same replace-not-push pattern as a search-result tap), so the user lands on the now-tag-scoped list; run tests green
- [x] 17.5 Commit: `feat(app): show note tags and filter the notes list by tag`

### 18. End-to-end check

- [ ] 18.1 Run the full server and app test suites; fix any cross-phase regressions
- [ ] 18.2 Manually walk the golden path in a dev build: create a nested note, rename it, confirm a linking note gets rewritten, tag it, move it, confirm the sidebar/backlinks/tags UI all reflect it live
- [ ] 18.3 Update `server/API.md` and `server/STORAGE.md` to describe the new path/link/tag surface
- [ ] 18.4 Commit: `docs(server): document vault paths, links, and tags`

## Definition of Done

- All tasks above checked off, each with its own green test run and its own commit
- `openspec validate add-vault-structure --strict` passes
- Full server (`dart test`) and Flutter (`flutter test`) suites pass
- A pre-existing flat `<id>.md` vault boots on the new server and migrates without manual steps
- Manual golden-path walk (18.2) completed and any UI regressions fixed
- No `TODO`/`FIXME` left from this change in touched files
