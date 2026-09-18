## Context

Storage (`server/lib/src/storage.dart`) already round-trips unknown frontmatter keys as `StoredNote.extra`, but nothing above it reads or writes them: `GET /notes/{id}` returns body only, `PUT` carries `extra` through untouched, and MCP tools never expose it. `MetaIndex` is an in-memory summary map used for `GET /notes` paging; `SearchIndex` owns `search.db` (FTS5 `notes_fts`, `link_edges`, optional `note_vectors`, `meta.schema_version = 4`) and every write goes through `NoteWriteService` which updates storage, the three indexes, and broadcasts. `LinkIndex` parses `[[...]]` from the body only. Locks are per-note editor locks checked by `PUT`/`DELETE`/MCP writes. See `proposal.md` for motivation and `specs/databases/spec.md` for the behavior.

## Goals / Non-Goals

**Goals:**

- Keep every database artifact (definition and row values) as plain YAML frontmatter in markdown files; the SQLite side is a rebuildable cache, like FTS today.
- One validation and one query implementation shared by REST and MCP.
- Property patches that cannot lose a concurrent body edit.
- Zero behavior change for vaults without any `type: database` note, other than `properties` appearing in note responses.

**Non-Goals:**

- Cross-row transactions, referential integrity for relations, or cascading deletes.
- Query performance beyond homelab scale (thousands of notes); no separate columnar store.
- View rendering; the server returns rows and group counts only.

## Decisions

**Definition notes are parsed into an in-memory `DatabaseRegistry`, rebuilt on startup from the `note_meta` table the search index already populates (no extra file pass) and updated on every write and delete.** Alternative: store definitions in SQLite. Rejected because definitions are few, need rich validation, and the registry must answer "which databases cover note X" on every property write, which is a simple in-memory scan over sources. The registry holds `DatabaseDefinition {id, title, path, source, properties, views}` parsed by `databases/definition.dart` from the note's extra map. `NoteWriteService.delete` removes the entry. A definition that fails validation is logged and skipped, matching the frontmatter-parse-failure behavior in `notes-storage`.

**Row membership is computed, never stored.** `source.folder` matches `NoteSummary.path` (prefix match when `include_subfolders`), `source.tag` matches the computed tag set (frontmatter plus inline). Both already exist on `NoteSummary`. Definitions (`type: database`) are always excluded. Alternative: a `database_id` key on rows. Rejected: it duplicates state the folder already expresses and breaks when files are moved by hand.

**Property values live in SQLite as an EAV table plus a plain metadata table; nothing is filtered or sorted through `notes_fts`.** `notes_fts` is an FTS5 virtual table whose non-content columns are `UNINDEXED`, so any predicate on it is a full scan. New tables in `search.db`:

- `note_meta(note_id TEXT PRIMARY KEY, title TEXT, path TEXT, created_at TEXT, updated_at TEXT, is_definition INTEGER, frontmatter_json TEXT)` with indexes on `(path)`, `(updated_at)`, `(created_at)`. `is_definition` is 1 for any note whose frontmatter has `type: database`, valid or not, so definitions are excluded from rows in SQL. `frontmatter_json` holds the property-key map (server-interpreted keys excluded) and hydrates `properties` in query results.
- `note_properties(note_id TEXT, key TEXT, ordinal INTEGER, text_value TEXT, num_value REAL, bool_value INTEGER, date_value TEXT, day_value TEXT)` with indexes on `(key, text_value)`, `(key, num_value)`, `(key, date_value)`; one row per scalar, list values expand to one row per element with `ordinal`. Every scalar is written to the column matching its YAML type (string → `text_value`, and when it parses as a date also `date_value` as a UTC instant plus `day_value` as `YYYY-MM-DD`; int/double → `num_value`; bool → `bool_value`). The computed tag set (frontmatter plus inline) is written under key `tags` so tag sources and `tags` filters are SQL. Typing is decided from the YAML value, not from any definition, so the index does not depend on the registry and one note covered by two databases is stored once.
- `kSearchSchemaVersion` 4 → 5, reusing the rebuild-on-mismatch path.

Alternative: query `MetaIndex` in memory. Rejected per the discussion: it does not scale and the user chose SQLite. Alternative: JSON1 `json_extract` over the blob only. Rejected: no usable indexes for sort or range predicates.

**Query compilation.** `databases/query.dart` turns a `Filter` tree into SQL: source narrowing first (`note_meta.path` prefix or `EXISTS` on `note_properties` key `tags`) plus `is_definition = 0`, then one `EXISTS` subquery per condition (so list-valued properties work without join fan-out), combinators as `AND`/`OR`. Built-ins come from `note_meta`. Sorting is in SQL with unset-last emulated by `CASE WHEN ... IS NULL`, final tie-break `id ASC`, default order `id ASC`. Pagination is keyset on `(sort_value, id)`; the cursor is base64 JSON `{s: <hash of the sort spec>, v: <last value>, id}` and is rejected when the hash does not match. `groups` is a second `GROUP BY` query over the same filtered id set. `row_count` for `GET /databases` is the same narrowing query with `COUNT(*)`.

**Validation lives in `databases/validation.dart` and runs only on caller-supplied values.** `validateProperties(coveringDefinitions, properties)` returns a list of `PropertyViolation {key, reason}`. `NoteWriteService` exposes `create`/`update` with an optional `properties` argument that is validated (against `registry.covering(path, tags)`) and a separate internal path used by rename propagation and migrations that passes `extra` through untouched and never validates; `patchProperties`, `createRow`, `createDatabase`, and `updateDatabase` validate what the caller sent. Routes and MCP both map a non-empty violation list to `validation_failed` with a `message` listing the keys. `shared` `ErrorCode` gains `validationFailed` and `pathConflict` so clients can decode the envelope. Rejected alternative: validate every write. It would make a hand-edited invalid value abort rename propagation half way through.

**Property patch is a new `NoteWriteService.patchProperties` built on a new `Storage.patchExtra(id, {set, unset})` that runs read, mutate, version bump, and atomic write inside the existing per-note mutex.** `Storage` today only exposes `update(..., ifMatch)` which takes the mutex itself, so a read-then-update from the service would race; the new method does the read-modify-write under the same lock `update` uses. A concurrent `PUT` is therefore serialized: whichever runs second sees the bumped version and gets `version_conflict` (PUT) or simply applies on top (patch). This is why the patch needs no `If-Match` from the client yet can never lose a body edit. It deliberately does not consult `LockManager`: editor locks protect the body a human is typing in, and a property patch cannot touch the body. Broadcasts `ChangedEvent(action: updated)`.

**Row creation and database creation are thin wrappers over `NoteWriteService.create`.** `createRow` resolves the path default from the source, merges the source tag into `tags` for tag sources, validates, then calls `create` with `extra`. `createDatabase` builds the `extra` map `{type: database, source, properties, views}`, validates it as a definition, and calls `create`; `updateDatabase` is `update` with `properties` replaced by the new definition sections. This keeps the version, broadcast, and index behavior identical to any note write, and lets the same file be edited by hand.

**Relations feed the link index by extending `LinkIndex.upsert` to accept extra link sources.** `NoteWriteService` computes `relationLinks(definitions, note)` (wikilinks from declared relation keys) and passes them alongside the body links; `link_edges` gains no schema change. Rename propagation already rewrites via parsed edges per note; it gains a frontmatter rewrite branch for edges whose origin is a relation key. Undeclared wikilinks in frontmatter are ignored so free-form YAML never surprises anyone with backlinks.

**Frontmatter serialization keeps key order and appends new keys.** `Storage` writes the six storage-managed keys first then `extra` in insertion order; `patchExtra` mutates the existing ordered map in place. The existing writer always double-quotes strings and emits lists in block style, so no value changes type on round-trip and tests must assert parsed values, not raw YAML text. Server-interpreted keys (`type`, `tags`, `source`, `properties`, `views`) stay inside `extra` exactly as today; the API layer filters them out of `properties` and the property writers refuse them, so a `properties`-replacing `PUT` rebuilds `extra` as server-interpreted keys plus the new property keys.

**Auth scope.** `auth_middleware` derives the scope from the HTTP method, which would make `POST /databases/{id}/query` a write. It gains a small per-route override table marking that route as `notes:read`.

**REST surface.** `server/routes/databases/index.dart` (GET list, POST create), `databases/[id]/index.dart` (GET, PUT), `databases/[id]/query.dart` (POST), `databases/[id]/rows.dart` (POST), `notes/[id]/properties.dart` (PATCH). `shared` gains `Routes.databases`, `Routes.database(id)`, `Routes.databaseQuery(id)`, `Routes.databaseRows(id)`, `Routes.noteProperties(id)` and DTOs for definitions, filters, views, and query pages so the app change can reuse them.

**MCP.** Seven tools added to `mcp/tools.dart` following the existing `McpTool` pattern; descriptions embed the filter grammar and encoding table verbatim so an agent needs no external doc. Scope gating reuses the existing write-scope check.

## Risks / Trade-offs

- [Risk] EAV filtering with several `EXISTS` subqueries could be slow on large vaults → Mitigation: source narrowing on `note_meta` happens first, the three `(key, value)` indexes cover every predicate, and the target scale is thousands of notes; a logged benchmark with 5k synthetic rows and a generous 2 s ceiling runs in the suite.
- [Risk] Typing from YAML values means an unquoted `due: 2026-10-01` written by another tool may load as a date object → Mitigation: the reader accepts strings and date objects and normalises both to ISO strings; the writer always quotes.
- [Risk] Rename propagation rewrites N notes and each rewrite re-indexes that note's EAV rows → accepted; same cost class as the FTS re-index that already happens per rewritten note.
- [Risk] A note covered by two databases with conflicting definitions for the same key → Mitigation: validation runs against both and the message names the database; documented as user error, not silently picking one.
- [Trade-off] Removing a property from a definition leaves stale keys in rows → accepted, mirrors Obsidian and avoids destructive schema edits; the app change can offer a cleanup later.
- [Trade-off] The property patch bypasses editor locks → accepted by the user; the editor receives the `changed` event and refreshes frontmatter without touching its body buffer (client change).
- [Trade-off] Definitions are not versioned separately from the note → the note version serves; `PUT /databases/{id}` uses it for `If-Match`.

## Migration Plan

1. Deploy: schema version bump triggers a one-time index rebuild on startup; no data file changes.
2. Existing vaults: nothing becomes a database until a `type: database` note exists; `properties` simply appears in note responses.
3. Rollback: revert the image; the previous server rebuilds `search.db` at schema 4 and ignores unknown frontmatter as before. Row files remain valid markdown.

- [Trade-off] `GET /databases` runs one count query per database → accepted; databases are few and each count is an indexed narrowing query.

## Open Questions

- Whether `GET /notes` list items should also carry `properties`. Deferred: `query_database` covers list-with-properties, and the list payload stays lean. Can be added later without breaking anything.
