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

**Definition notes are parsed into an in-memory `DatabaseRegistry`, rebuilt from `MetaIndex` on startup and updated on every write.** Alternative: store definitions in SQLite. Rejected because definitions are few, need rich validation, and the registry must answer "which databases cover note X" on every property write, which is a simple in-memory scan over sources. The registry holds `DatabaseDefinition {id, title, path, source, properties, views}` parsed by `databases/definition.dart` from `StoredNote.extra`. A definition that fails validation is logged and skipped, matching the frontmatter-parse-failure behavior in `notes-storage`.

**Row membership is computed, never stored.** `source.folder` matches `NoteSummary.path` (prefix match when `include_subfolders`), `source.tag` matches the computed tag set (frontmatter plus inline). Both already exist on `NoteSummary`. Definitions (`type: database`) are always excluded. Alternative: a `database_id` key on rows. Rejected: it duplicates state the folder already expresses and breaks when files are moved by hand.

**Property values live in SQLite as an EAV table plus a JSON blob.** New tables in `search.db`:

- `note_properties(note_id TEXT, key TEXT, ordinal INTEGER, text_value TEXT, num_value REAL, bool_value INTEGER, date_value TEXT)` with an index on `(key, text_value)` and `(key, num_value)`; one row per scalar, list values expand to one row per element with `ordinal`. Every scalar is written to the column matching its YAML type (string → `text_value` and, when it parses as a date, also `date_value`; int/double → `num_value`; bool → `bool_value`). Typing is decided from the YAML value, not from any definition, so the index does not depend on the registry and one note covered by two databases is stored once.
- `note_frontmatter(note_id TEXT PRIMARY KEY, json TEXT)` holding the full non-reserved extra map as JSON, used to hydrate `properties` in query results.
- `kSearchSchemaVersion` 4 → 5, reusing the rebuild-on-mismatch path.

Alternative: query `MetaIndex` in memory. Rejected per the discussion: it does not scale and the user chose SQLite. Alternative: JSON1 `json_extract` over the blob only. Rejected: no usable indexes for sort or range predicates.

**Query compilation.** `databases/query.dart` turns a `Filter` tree into SQL over `note_properties` using `EXISTS` subqueries per condition (so list-valued properties and multi-database coverage work without joins exploding), unioned with the built-in fields read from `notes_fts` (`title`, `path`, `updated_at`) and `note_frontmatter`. Sorting is done in SQL with `NULLS LAST` semantics emulated by `CASE WHEN ... IS NULL`, final tie-break `id ASC`. Pagination is keyset on `(sort_value, id)`; the cursor is base64 JSON `{s: <sort spec hash>, v: <last value>, id}` and is rejected when the hash does not match the sort in effect. `groups` is a second `GROUP BY` query over the same filtered id set. The candidate id set is first narrowed by the source (path prefix or tag), which the query passes as a `WHERE` on `notes_fts.path` or an `EXISTS` on `note_properties` key `tags`... tags are not frontmatter-only, so the index also writes the computed tag set into `note_properties` under the reserved key `tags` (it is read-only from the API side). `created_at` is not in `notes_fts` today; the write path adds it to `note_frontmatter` as a sibling column `created_at TEXT`.

**Validation lives in `databases/validation.dart` and is called from `NoteWriteService`, not the routes.** `validateProperties(definitions, note summary-ish, properties)` returns a list of `PropertyViolation {key, reason}`. It is invoked for `create`, `update` (when `properties` supplied), `patchProperties`, and `createRow`, using the registry to find covering databases for the target `path` and the effective tags. Routes and MCP both map a non-empty violation list to `validation_failed` with a `message` listing the keys. Rejected alternative: validate only in the typed database endpoints. The user asked for schema violations to be rejected; a `PUT /notes/{id}` carrying `properties` is just as typed.

**Property patch is a new `NoteWriteService.patchProperties` that holds the storage per-note lock, reads the current file, mutates only frontmatter extras, and writes with `ifMatch = current.version`.** Because the read and write happen inside `Storage._withLock(id)` (the same mutex `update` uses), a concurrent `PUT` is serialized: whichever runs second sees the bumped version and gets `version_conflict` (PUT) or simply applies on top (patch). This is why the patch needs no `If-Match` from the client yet can never lose a body edit. It deliberately does not consult `LockManager`: editor locks protect the body a human is typing in, and a property patch cannot touch the body. Broadcasts `ChangedEvent(action: updated)`.

**Row creation and database creation are thin wrappers over `NoteWriteService.create`.** `createRow` resolves the path default from the source, merges the source tag into `tags` for tag sources, validates, then calls `create` with `extra`. `createDatabase` builds the `extra` map `{type: database, source, properties, views}`, validates it as a definition, and calls `create`; `updateDatabase` is `update` with `properties` replaced by the new definition sections. This keeps the version, broadcast, and index behavior identical to any note write, and lets the same file be edited by hand.

**Relations feed the link index by extending `LinkIndex.upsert` to accept extra link sources.** `NoteWriteService` computes `relationLinks(definitions, note)` (wikilinks from declared relation keys) and passes them alongside the body links; `link_edges` gains no schema change. Rename propagation already rewrites via parsed edges per note; it gains a frontmatter rewrite branch for edges whose origin is a relation key. Undeclared wikilinks in frontmatter are ignored so free-form YAML never surprises anyone with backlinks.

**Frontmatter serialization keeps key order and appends new keys.** `Storage` already writes reserved keys first then `extra` in insertion order; `patchProperties` mutates the existing `LinkedHashMap` in place so order is preserved. Lists are emitted in YAML block style; strings that would parse as another scalar (`"12"`, `"true"`, `"2026-10-01"`) are quoted, using the existing writer's quoting rule.

**REST surface.** `server/routes/databases/index.dart` (GET list, POST create), `databases/[id]/index.dart` (GET, PUT), `databases/[id]/query.dart` (POST), `databases/[id]/rows.dart` (POST), `notes/[id]/properties.dart` (PATCH). `shared` gains `Routes.databases`, `Routes.database(id)`, `Routes.databaseQuery(id)`, `Routes.databaseRows(id)`, `Routes.noteProperties(id)` and DTOs for definitions, filters, views, and query pages so the app change can reuse them.

**MCP.** Seven tools added to `mcp/tools.dart` following the existing `McpTool` pattern; descriptions embed the filter grammar and encoding table verbatim so an agent needs no external doc. Scope gating reuses the existing write-scope check.

## Risks / Trade-offs

- [Risk] EAV filtering with several `EXISTS` subqueries could be slow on large vaults → Mitigation: source narrowing happens first, both `(key, text_value)` and `(key, num_value)` are indexed, and the target scale is thousands of notes; measured in a test with 5k synthetic rows before merge.
- [Risk] Typing from YAML values means `due: 2026-10-01` unquoted is parsed by the YAML loader as a string in this project's loader but could become a date object in other tools → Mitigation: the writer always quotes date strings; the reader accepts both and normalises to ISO strings.
- [Risk] A note covered by two databases with conflicting definitions for the same key → Mitigation: validation runs against both and the message names the database; documented as user error, not silently picking one.
- [Trade-off] Removing a property from a definition leaves stale keys in rows → accepted, mirrors Obsidian and avoids destructive schema edits; the app change can offer a cleanup later.
- [Trade-off] The property patch bypasses editor locks → accepted by the user; the editor receives the `changed` event and refreshes frontmatter without touching its body buffer (client change).
- [Trade-off] Definitions are not versioned separately from the note → the note version serves; `PUT /databases/{id}` uses it for `If-Match`.

## Migration Plan

1. Deploy: schema version bump triggers a one-time index rebuild on startup; no data file changes.
2. Existing vaults: nothing becomes a database until a `type: database` note exists; `properties` simply appears in note responses.
3. Rollback: revert the image; the previous server rebuilds `search.db` at schema 4 and ignores unknown frontmatter as before. Row files remain valid markdown.

## Open Questions

- Whether `GET /notes` list items should also carry `properties`. Deferred: `query_database` covers list-with-properties, and the list payload stays lean. Can be added later without breaking anything.
