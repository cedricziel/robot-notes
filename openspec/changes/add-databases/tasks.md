# Tasks

Each task is a TDD step: write the failing test named in the task, make it pass, commit atomically with a conventional message (`feat(databases): ...`, `test(databases): ...`). Dependencies: group 1 is independent. Group 2 depends on 1.2. Group 3 depends on 1.2. Group 4 depends on 2, 3, and 1. Groups 5 and 6 depend on 1 to 4 and are independent of each other. Group 7 depends on 5 and 6. Group 8 depends on everything.

## 1. Shared contracts

- [x] 1.1 Add `validationFailed('validation_failed')` and `pathConflict('path_conflict')` to `ErrorCode` in `shared/lib/src/errors.dart` and make `server/lib/src/mcp/tool_results.dart` use them; failing test: `ErrorEnvelope.fromJson({'error':'validation_failed'})` round-trips
- [x] 1.2 Add `Routes.databases`, `Routes.database(id)`, `Routes.databaseQuery(id)`, `Routes.databaseRows(id)`, `Routes.noteProperties(id)` to `shared/lib/src/routes.dart`; failing `shared` test asserting the literal paths
- [x] 1.3 Add DTOs in `shared/lib/src/dtos.dart`: `PropertyType` enum, `PropertyDefinition`, `DatabaseSource`, `SortSpec`, `Filter` (sealed: `Condition`, `And`, `Or`), `ViewDefinition`, `DatabaseDefinition`, `DatabaseSummary`, `DatabaseRow`, `DatabaseQueryPage`, `GroupCount`, `PropertyPatch`; failing round-trip `toJson`/`fromJson` tests including nested filters — tests live in `shared/test/database_dtos_test.dart` rather than being folded into `dtos_test.dart`, for size; `coveringDatabases` (1.5) lives in the same file since it operates on `DatabaseDefinition`
- [x] 1.4 Add `properties` (and optional `type`) to the shared full-note DTO; failing test decoding a note with properties; existing DTO tests still pass
- [x] 1.5 Add `coveringDatabases(path, tags, definitions)` to `shared` (folder prefix with `include_subfolders`, tag membership, never the definition itself); failing tests for each rule

## 2. Definition parsing and validation (server, pure)

- [x] 2.1 Create `server/lib/src/databases/definition.dart` with `DatabaseDefinition.fromExtra(id, title, path, extra)`; failing tests: recognises `type: database`, defaults `source` to own folder with subfolders, parses every property type, parses views; implement - deviated: the shared `DatabaseDefinition` DTO (from group 1) is a plain immutable class in another package with no `fromExtra` constructor slot, so this is a top-level function `parseDatabaseDefinition({id, title, path, extra, version, createdAt, updatedAt})` in `server/lib/src/databases/definition.dart` that returns the shared DTO; `version`/`createdAt`/`updatedAt` are optional (default to `1`/epoch) since pure structural parsing doesn't need them, and real call sites (the registry) pass the note's actual values
- [x] 2.2 Failing tests for definition validation errors (reserved or server-interpreted key, bad key pattern, unknown type, select without options or with duplicates, duplicate view names case-insensitive, board without `group_by`, `group_by` not a select for boards, filter referencing undeclared property, inapplicable operator, `is_empty` with a value) each producing a `DefinitionViolation` naming the offending path; implement `validateDefinition` - "unknown type" can't reach `validateDefinition` since `parseDatabaseDefinition` already throws `DefinitionFormatException` for it (see 2.1's deviation); the corresponding test instead exercises another semantic-only rule (`multi_select` without `options`)
- [x] 2.3 Create `server/lib/src/databases/validation.dart` with `validateProperties(List<DatabaseDefinition> covering, Map<String, Object?> properties)`; failing tests per type: text, number (string form rejected), checkbox, date day and timestamp, select option, multi_select list of options, relation wikilink list, url absolute http(s) only, reserved and server-interpreted keys rejected, built-ins rejected, nested map rejected, `null` means unset; implement
- [x] 2.4 Relation target constraint: `validateProperties` takes a resolver `(title) -> NoteSummary?` and a row-membership check; failing tests: target that is a row of the constrained database accepted, target that is not rejected, unresolved title accepted; implement - both are optional named parameters (`resolveTitle`, `isRowOf`) so callers that never touch relations, and 2.3's tests, can omit them
- [x] 2.5 Failing tests for `DatabaseRegistry` (`server/lib/src/databases/registry.dart`): `rebuild(Iterable<(NoteSummary, extra)>)` registers valid definitions and skips invalid ones with a log line naming the file; `upsert`/`remove`; `covering(path, tags)` returns definitions whose source matches and never a definition for itself; implement - `covering` delegates to the shared `coveringDatabases` helper from group 1 rather than reimplementing the self-exclusion/source-match rules

## 3. Property index in SQLite

- [ ] 3.1 Bump `kSearchSchemaVersion` to 5; add `note_meta` and `note_properties` tables with the indexes from design.md in `_initSchema`; failing test: a schema-4 db is rebuilt on open and the new tables and indexes exist
- [ ] 3.2 `SearchIndex.upsert` gains `extra`, `createdAt`, `isDefinition`; writes `note_meta` (property-key JSON with server-interpreted keys excluded) and EAV rows (scalars typed by YAML value, lists expanded with ordinal, date strings and date objects normalised to `date_value` plus `day_value`, computed tags under key `tags`); failing tests per encoding; `delete` removes rows from both tables
- [ ] 3.3 Thread the new `upsert` arguments through the rebuild scan and existing test call sites (production `NoteWriteService` call sites are updated in 4.3); full server suite green
- [ ] 3.4 `SearchIndex.definitionsSource()` returns `(NoteSummary-ish, extra)` for every `is_definition = 1` row so the registry can rebuild without file reads; failing test; implement
- [ ] 3.5 `databases/query.dart` part 1: source narrowing to an id set (folder with and without subfolders, tag) excluding `is_definition`; failing tests; implement
- [ ] 3.6 Query part 2: condition compilation for each operator on each applicable type, including date day vs instant semantics, ASCII case-insensitive `contains`, and `is_empty` covering missing, null, empty string, empty list; failing tests; implement
- [ ] 3.7 Query part 3: `and`/`or` combinators nested; failing tests; implement
- [ ] 3.8 Query part 4: sort on properties and built-ins, unset-last both directions, `id` tie-break, default `id asc`; failing tests; implement
- [ ] 3.9 Query part 5: keyset cursor encode/decode with sort-spec hash, three-page pagination, cursor rejected under a different sort; failing tests; implement
- [ ] 3.10 Query part 6: group counts in option order with zero buckets for selects, distinct ascending for other types, trailing null bucket; `count(...)` helper for `row_count`; failing tests; implement
- [ ] 3.11 Benchmark test: 5,000 synthetic rows with 5 properties, two-condition filter with sort and limit 50; logs the duration and fails only above 2 s

## 4. Write path

- [ ] 4.1 `Storage.create`/`update` accept `properties` and rebuild `extra` as server-interpreted keys plus the given property keys; failing tests: create writes property keys after storage-managed keys, update with `properties` omitted preserves all extras, update with `properties` supplied removes other property keys but keeps `tags`/`type`/`source`/`views`, key order preserved and new keys appended, values asserted by parsing the file back; implement
- [ ] 4.2 `Storage.patchExtra(id, {set, unset})` running read, mutate, version bump, `updated_at`, atomic write inside the per-note mutex; failing tests: two concurrent patches both apply, a concurrent `update` with a stale `ifMatch` gets `VersionConflictException`, body byte-identical; implement
- [ ] 4.3 `NoteWriteService.create`/`update` accept `properties`, validate via the registry (throwing `PropertyValidationException` listing violations), pass through to storage and `searchIndex.upsert` with `extra`, `createdAt`, `isDefinition`, and refresh the registry when the written note is or was a definition; an internal `updateRaw` used by rename propagation never validates; failing tests for each, including the rename-tolerates-invalid-value scenario; implement
- [ ] 4.4 `NoteWriteService.delete` removes the registry entry; failing test: deleting a definition makes `registry.get` null; implement
- [ ] 4.5 `NoteWriteService.patchProperties(id, set, unset, actor)` part 1: set and unset merge via `patchExtra`, body preserved, returns the stored note; failing tests; implement
- [ ] 4.6 `patchProperties` part 2: rejection cases (empty, key in both, built-in, reserved or server-interpreted key, schema violation) leave the file untouched; failing tests; implement
- [ ] 4.7 `patchProperties` part 3: ignores the editor lock held by another actor and broadcasts `changed` `updated` with the new version; failing tests; implement
- [ ] 4.8 `patchProperties` part 4: concurrency with `update(ifMatch)` serialises (one `version_conflict`, patched key present); failing test; implement
- [ ] 4.9 `NoteWriteService.createRow(databaseId, title, properties, content, path)` resolving path default, rejecting paths outside a folder source, adding the source tag for tag sources; failing tests; implement
- [ ] 4.10 `NoteWriteService.createDatabase(...)` and `updateDatabase(id, ifMatch, ...)` building and validating the definition `extra`, delegating to `create`/`update`, surfacing `path_conflict`; failing tests including `version_conflict` and that a body-only `update` on a definition preserves `type/source/properties/views`; implement
- [ ] 4.11 Relations: compute wikilinks from declared relation keys and feed them to `LinkIndex`/`link_edges` alongside body links; failing tests: backlink appears, undeclared frontmatter wikilink does not, `GET /notes/{id}/links` lists it; implement
- [ ] 4.12 Rename propagation rewrites relation values in frontmatter (not only body links), bumping the row version; failing test; implement

## 5. REST routes

- [ ] 5.1 Auth: per-route scope override so `POST /databases/{id}/query` needs `notes:read`; failing tests: read token gets 200 on query and 403 on `POST /databases/{id}/rows`; implement
- [ ] 5.2 `GET /notes/{id}` returns `properties` and `type` for definitions; `POST /notes` and `PUT /notes/{id}` accept `properties` with `validation_failed` on violations; failing route tests per `notes-api` delta scenarios; implement
- [ ] 5.3 `PATCH /notes/{id}/properties` in `server/routes/notes/[id]/properties.dart`; failing route tests for 200 shape, 400 on empty or reserved, 404, no `If-Match` needed, lock ignored, broadcast observed; implement
- [ ] 5.4 `GET /databases` (with `row_count`) and `POST /databases`; failing tests for list shape, 201 and file on disk, 400 per validation error class, 409 `path_conflict`; implement `server/routes/databases/index.dart`
- [ ] 5.5 `GET /databases/{id}` and `PUT /databases/{id}`; failing tests for 404 on non-database note, 428 without `If-Match`, 409 on stale, wholesale replacement of supplied sections, property removal keeps row values, 404 after the definition is deleted; implement `server/routes/databases/[id]/index.dart`
- [ ] 5.6 `POST /databases/{id}/query`; failing tests for saved view, request overrides, groups, pagination, unknown view 400, limit bounds, tag source, item shape without `content`; implement `server/routes/databases/[id]/query.dart`
- [ ] 5.7 `POST /databases/{id}/rows`; failing tests for default path, tag added, path outside source rejected, validation failure writes nothing, 201 shape; implement `server/routes/databases/[id]/rows.dart`
- [ ] 5.8 Unauthenticated requests to each new route return 401; verify with route tests

## 6. MCP tools

- [ ] 6.1 Extend `_validateArgs` with `object`, `array`, `boolean`, `number` cases raising invalid params; failing tests per type; implement
- [ ] 6.2 `get_note` returns `properties`; `create_note`/`update_note` accept `properties` (update with only `properties` is valid); failing tool tests; implement
- [ ] 6.3 Add `list_databases`, `get_database`, `create_database`, `update_database`; failing tests for catalog names and `required` arrays, structured content parity with REST, `not_found`, `version_conflict`, `path_conflict`, write-scope gating; implement
- [ ] 6.4 Add `query_database`, `create_row`, `update_properties`; failing tests for parity with REST including `validation_failed` on bad option, `groups` present when grouped, lock ignored, `changed` broadcast on patch, read scope allowed on query; implement
- [ ] 6.5 Update the `tools/list` catalog test to the nineteen names with the exact `required` arrays and verify tool descriptions contain the filter grammar and the per-type encoding table (string-contains assertions)

## 7. Startup and consistency

- [ ] 7.1 Wire `DatabaseRegistry` into `AppDeps.bootstrap` after `SearchIndex.open`, rebuilt from `definitionsSource()`, provided to routes and MCP; failing startup test: a vault with one valid and one invalid definition registers exactly one and logs the other, with no extra file reads (count reads via a spying storage)
- [ ] 7.2 Integration tests: moved note leaves the database on next query; source change takes effect on next query; property written via `PUT` is queryable immediately; index rebuild after schema bump restores property queries; a malformed `type: database` note is never a row

## 8. Docs and wrap-up

- [ ] 8.1 Document every new endpoint, the definition frontmatter format, property encodings, date semantics, and the filter grammar in `server/API.md`; add the seven tools to the tool catalog section; verify by reading the rendered sections back
- [ ] 8.2 Add a worked example to `README.md` (create a Projects database, add a row, query the board) using `curl`; verify the commands run against a dev server
- [ ] 8.3 Run `dart analyze`, `dart format --set-exit-if-changed`, and the full `server` and `shared` suites; verify clean

## Definition of Done

- [ ] Every scenario in `specs/databases/spec.md` and the seven delta specs has a passing test.
- [ ] `dart analyze` clean, formatting clean, full workspace test suite green.
- [ ] All seven MCP tools callable end to end against a running server with a real MCP client (manual check recorded in the PR).
- [ ] `server/API.md` and `README.md` updated.
- [ ] `openspec validate add-databases --strict` passes.
- [ ] Every commit atomic and conventional, each feature commit preceded by a failing test commit or containing the test.
