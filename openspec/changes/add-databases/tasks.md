# Tasks

Each task is a TDD step: write the failing test named in the task, make it pass, commit atomically with a conventional message (`feat(databases): ...`, `test(databases): ...`). Groups 1 to 3 are independent of each other and can proceed in parallel branches; groups 4 to 7 depend on 1 to 3; group 8 depends on everything.

## 1. Shared contracts

- [ ] 1.1 Add `Routes.databases`, `Routes.database(id)`, `Routes.databaseQuery(id)`, `Routes.databaseRows(id)`, `Routes.noteProperties(id)` to `shared/lib/src/routes.dart`; verify with a `shared` test asserting the literal paths
- [ ] 1.2 Add DTOs in `shared/lib/src/dtos.dart`: `PropertyType` enum, `PropertyDefinition`, `DatabaseSource`, `SortSpec`, `Filter` (sealed: `Condition`, `And`, `Or`), `ViewDefinition`, `DatabaseDefinition`, `DatabaseSummary`, `DatabaseRow`, `DatabaseQueryPage`, `GroupCount`; verify with round-trip `toJson`/`fromJson` tests including nested filters
- [ ] 1.3 Add `properties` to the shared full-note DTO (`NoteDetail` or equivalent) as `Map<String, Object?>`; verify existing DTO tests still pass and a new test decodes a note with properties

## 2. Definition parsing and validation (server, pure)

- [ ] 2.1 Create `server/lib/src/databases/definition.dart` with `DatabaseDefinition.fromExtra(id, title, path, extra)`; failing tests: recognises `type: database`, defaults `source` to own folder, parses every property type, parses views; then implement
- [ ] 2.2 Write failing tests for definition validation errors (reserved key, bad key pattern, unknown type, select without options, duplicate view names, board without `group_by`, `group_by` not a select, filter referencing undeclared property, inapplicable operator) each producing a `DefinitionViolation` with the offending path; implement `validateDefinition`
- [ ] 2.3 Create `server/lib/src/databases/validation.dart` with `validateProperties(List<DatabaseDefinition> covering, Map<String, Object?> properties)`; failing tests per type for accepted and rejected encodings (text, number as string rejected, checkbox, date day and timestamp, select option, multi_select list, relation wikilink list, url absolute only, reserved keys, built-ins rejected, nested map rejected, `null` means unset); implement
- [ ] 2.4 Write failing tests for `DatabaseRegistry` (`server/lib/src/databases/registry.dart`): `rebuild(Iterable<NoteSummary>, read extra)` registers valid definitions and skips invalid ones with a log line naming the file; `upsert`/`remove` on writes; `covering(path, tags)` returns definitions whose source matches, never returning a definition for itself; implement

## 3. Property index in SQLite

- [ ] 3.1 Bump `kSearchSchemaVersion` to 5 and add `note_properties` and `note_frontmatter` tables plus indexes in `_initSchema`; failing test: a schema-4 db is rebuilt on open, and the new tables exist
- [ ] 3.2 Extend `SearchIndex.upsert` with `extra: Map<String, Object?>`, `createdAt`, and write EAV rows (scalars typed by YAML value, lists expanded with ordinal, computed `tags` under key `tags`, date-shaped strings also into `date_value`) plus the JSON blob; failing tests for each encoding; verify delete removes the rows
- [ ] 3.3 Thread `extra` and `createdAt` through every existing `upsert` call site (`NoteWriteService.create/update`, rebuild scan, tests); verify the full server suite passes
- [ ] 3.4 Create `server/lib/src/databases/query.dart`: compile `Filter` + `SortSpec` + source narrowing into SQL over `note_properties`/`note_frontmatter`/`notes_fts`; failing tests for every operator on every applicable type, nested and/or, source folder with and without subfolders, tag source, definition exclusion, sort with unset-last both directions and `id` tie-break, keyset pagination across 3 pages, cursor rejected under a different sort, group counts in option order with a null bucket; implement
- [ ] 3.5 Add a performance guard test: 5,000 synthetic rows with 5 properties, a two-condition filter with sort and limit 50 completes under 200 ms on CI hardware; tune indexes if it fails

## 4. Write path

- [ ] 4.1 `Storage.create`/`update` accept `extra`; failing tests: create writes property keys after reserved keys, update with `extra` omitted preserves existing extras, update with `extra` supplied replaces them, key order is preserved and new keys appended, strings that look like numbers, booleans, or dates are quoted; implement
- [ ] 4.2 `NoteWriteService.create`/`update` accept `properties`, validate against `registry.covering(...)` (throwing `PropertyValidationException` listing violations), pass `extra` to storage and to `searchIndex.upsert`, and refresh the registry when the written note is or was a definition; failing tests for each; implement
- [ ] 4.3 `NoteWriteService.patchProperties(id, set, unset, actor)` inside the storage per-note lock, no lock-manager check, validated, version bump, `changed` broadcast with `updated`; failing tests: body byte-identical, other keys preserved, set plus unset, key in both rejected, empty rejected, built-in rejected, editor lock held by another actor still succeeds, concurrent patch and `PUT If-Match` serialize (one `version_conflict`, patched key present); implement
- [ ] 4.4 `NoteWriteService.createRow(databaseId, title, properties, content, path)` resolving path default, rejecting paths outside a folder source, adding the source tag for tag sources; failing tests; implement
- [ ] 4.5 `NoteWriteService.createDatabase(...)` and `updateDatabase(id, ifMatch, ...)` building and validating the definition `extra`, delegating to `create`/`update`; failing tests including `version_conflict` and that a body-only `PUT` on a definition preserves `type/source/properties/views`; implement
- [ ] 4.6 Relations: compute wikilinks from declared relation keys, feed them to `LinkIndex.upsert` and `link_edges`; failing tests: backlink appears, undeclared frontmatter wikilink does not, rename propagation rewrites the relation value and bumps the row version; implement

## 5. REST routes

- [ ] 5.1 `GET /notes/{id}` returns `properties` and `type` for definitions; `POST /notes` and `PUT /notes/{id}` accept `properties` with `validation_failed` on violations; failing route tests per `notes-api` delta scenarios; implement
- [ ] 5.2 `PATCH /notes/{id}/properties`; failing route tests for 200 shape, 400 on empty or reserved, 404, no `If-Match` needed, broadcast observed; implement `server/routes/notes/[id]/properties.dart`
- [ ] 5.3 `GET /databases` and `POST /databases`; failing route tests for list shape with `row_count`, 201 on create and file on disk, 400 on each validation error class, `path_conflict`; implement `server/routes/databases/index.dart`
- [ ] 5.4 `GET /databases/{id}` and `PUT /databases/{id}`; failing tests for 404 on non-database note, 428 without `If-Match`, 409 on stale, wholesale replacement of supplied sections, property removal keeps row values; implement `server/routes/databases/[id]/index.dart`
- [ ] 5.5 `POST /databases/{id}/query`; failing tests for saved view, request overrides, groups, pagination, unknown view 400, limit bounds, tag source; implement `server/routes/databases/[id]/query.dart`
- [ ] 5.6 `POST /databases/{id}/rows`; failing tests for default path, tag added, path outside source rejected, validation failure writes nothing; implement `server/routes/databases/[id]/rows.dart`
- [ ] 5.7 Register the new routes in `auth_middleware`/scope checks like existing note routes; verify an unauthenticated request to each new route is 401 and a read-only token gets 403 on writes

## 6. MCP tools

- [ ] 6.1 `get_note` returns `properties`; `create_note`/`update_note` accept `properties` (update with only `properties` is valid); failing tool tests; implement
- [ ] 6.2 Add `list_databases`, `get_database`, `create_database`, `update_database`; failing tests for catalog names and `required` arrays, structured content parity with REST, `not_found`, `version_conflict`, write-scope gating; implement
- [ ] 6.3 Add `query_database`, `create_row`, `update_properties`; failing tests for parity with REST including `validation_failed` on bad option, `groups` present when grouped, `changed` broadcast on patch; implement
- [ ] 6.4 Update the `tools/list` catalog test to the nineteen names and verify tool descriptions contain the filter grammar and the per-type encoding table (string-contains assertions)

## 7. Startup and consistency

- [ ] 7.1 Wire `DatabaseRegistry` into `AppDeps.bootstrap` after `MetaIndex.scan`, providing it to routes and MCP; failing startup test: a vault with one valid and one invalid definition registers exactly one and logs the other
- [ ] 7.2 Integration tests: moved note leaves the database on next query; source change takes effect on next query; property written via `PUT` is queryable immediately; index rebuild after schema bump restores property queries

## 8. Docs and wrap-up

- [ ] 8.1 Document every new endpoint, the definition frontmatter format, property encodings, and the filter grammar in `server/API.md`; add the seven tools to the tool catalog section; verify by reading the rendered sections back
- [ ] 8.2 Add a worked example to `README.md` (create a Projects database, add a row, query the board) using `curl`; verify the commands run against a dev server
- [ ] 8.3 Run `dart analyze`, `dart format --set-exit-if-changed`, and the full `server` and `shared` suites; verify clean

## Definition of Done

- [ ] Every scenario in `specs/databases/spec.md` and the five delta specs has a passing test.
- [ ] `dart analyze` clean, formatting clean, full workspace test suite green.
- [ ] All seven MCP tools callable end to end against a running server with a real MCP client (manual check recorded in the PR).
- [ ] `server/API.md` and `README.md` updated.
- [ ] `openspec validate add-databases --strict` passes.
- [ ] Every commit atomic and conventional, each feature commit preceded by a failing test commit or containing the test.
