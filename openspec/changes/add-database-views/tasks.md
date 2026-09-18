# Tasks

TDD throughout: each task names its failing widget or unit test first. Conventional commits (`feat(app): ...`, `test(app): ...`). Dependencies: 1.1 (the spike) comes first and is blocking. Group 1 is otherwise independent. Group 2 depends on 1. Group 3 depends on 1. Groups 4 to 7 depend on 1 to 3. Group 8 depends on everything. Requires the `add-databases` server change (including its shared `coveringDatabases` helper and DTOs) to be merged; unit and widget tests use a fake client.

## 1. Spike, API client, and error mapping

- [x] 1.1 Spike: confirm flutter_markdown_plus custom `BlockSyntax` plus `MarkdownElementBuilder` can claim a whole line `![[...]]` without affecting inline text; record the outcome in design.md; if unsupported, switch the design to the segment pre-pass before any other task starts — confirmed supported; spike kept as a real test at `app/test/src/databases/database_embed_syntax_spike_test.dart` backed by `app/lib/src/databases/database_embed_syntax.dart`, which task 7.2 builds on
- [ ] 1.2 Extend `Note` with `properties` and `type`; add `listDatabases`, `getDatabase`, `createDatabase`, `updateDatabase`, `queryDatabase`, `createRow`, `patchProperties` to `RobotNotesClient` using the shared DTOs and `Routes`; failing tests with a mock HTTP client asserting method, path, headers (`If-Match` on update), and body per endpoint; implement
- [x] 1.3 Map 409 `version_conflict` without `current` to `VersionConflictException` with a null `current`; regression test that 400 `validation_failed` still yields `BadRequestException` with the message; implement
- [x] 1.4 Extract title search from `NoteController.searchLinkTitles` into a standalone `TitleSearchService` usable without a note, with an optional database restriction via `queryDatabase`; failing tests; implement and re-point `NoteController` — `queryDatabase` doesn't exist yet (blocked on 1.2, out of scope for this agent), so `databaseRestriction` is a plain `Future<List<String>> Function(String query)?` hook for now; callers can wire it to `queryDatabase` once it lands

## 2. Routing and server shell fallback

- [ ] 2.1 Add `GoRoute('/databases/:id')` inside the existing shell with `view` query parsing; failing router tests for deep link, setup redirect, close-to-list, and the list pane scoped to the source folder; unknown-view fallback rewriting the URL is tested in 5.1 once the controller exists; implement
- [ ] 2.2 Add `GET /databases/{id}` to the server's dual-use path check with `Vary: Accept, Authorization`, keeping bare `GET /databases` API-only; failing server tests: browser-style request gets `index.html`, non-browser gets 401, bare list gets 401; implement

## 3. Controllers

- [ ] 3.1 `DatabasesController`: list for sidebar and embed resolution, title lookup with NFC case-insensitive match, cache of full definitions filled on demand, 1 s debounced refresh and cache invalidation on any `changed`; failing tests; implement
- [ ] 3.2 `DatabaseController`: load definition from the cache, select view, table and list paging, per-column board paging with filter override, groups, optimistic patch with revert, "left the view" detection with undo, debounced re-query on `changed`, loading, empty, error, and not-found states; failing tests using a fake client and fake WS stream; implement
- [ ] 3.3 `NoteController`: `properties` and covering definitions in state (via shared `coveringDatabases` and the definition cache), `patchProperty` serialized with autosave (cancel, wait for in-flight save, adopt returned version, re-arm), `changed` while editing refreshes displayed properties only and never the version; failing tests for every panel scenario including "patch during an armed autosave causes no conflict"; implement

## 4. Property editors

- [ ] 4.1 `PropertyEditor` widget family for text, url, number, checkbox, date, select, multi_select, relation (multi-value list via `TitleSearchService`, restricted by `database` when declared); failing widget tests per type that committing yields the right `PropertyPatch` and clearing yields `unset`; implement
- [ ] 4.2 Read-only renderers for built-ins (`tags` chips, relative dates, path text) and for values the editor cannot represent; widget tests; implement
- [ ] 4.3 Invalid-value styling and inline error display; widget test that a `validation_failed` result reverts and shows the message; implement

## 5. Database screen

- [ ] 5.1 Screen scaffold with title, view switcher updating the URL (including unknown-view fallback), New row, schema editor action, loading, empty, error, and not-found states; widget tests; implement
- [ ] 5.2 Table view with title column plus view keys (properties and built-ins), inline cell editing through `PropertyEditor`, invalid highlighting, infinite scroll paging, left-the-view notice with undo; widget tests; implement
- [ ] 5.3 List view with title and property chips; widget test; implement
- [ ] 5.4 Board view with option-ordered columns, counts, No value column, per-column paging with Load more, drag-and-drop patching with optimistic move and revert; widget tests; implement
- [ ] 5.5 New row flow: title prompt, `createRow`, navigate to `/notes/{id}?edit=1`; widget test; implement

## 6. Schema editor and creation form

- [ ] 6.1 New-database form in the sidebar (title, folder or tag source, definition-note location, properties, first view) posting to `POST /databases`, inline server errors; widget tests; implement
- [ ] 6.2 Schema editor: properties CRUD with key validation and removal warning, select options, relation target; widget tests; implement
- [ ] 6.3 Schema editor: views CRUD with reorder, group_by, sort, one-level filter builder, visible properties; `PUT` with `If-Match`; 409 reloads via `GET /databases/{id}` keeping edits; widget tests; implement

## 7. Note view integration

- [ ] 7.1 Property panel above the body, typed editors for declared properties, read-only rows for undeclared, collapsible with remembered state; widget tests; implement
- [ ] 7.2 `DatabaseEmbed` widget resolving title and view through the cache, rendering read-only table or board limited to 50 with Show all, literal fallback, bounded height, tappable inside `SelectionArea`, rendered in view mode and the edit preview pane, debounced refresh; widget tests; implement
- [ ] 7.3 Sidebar Databases section with navigation; widget test; implement

## 8. Wrap-up

- [ ] 8.1 Update the `flutter-client` user-facing docs section in `README.md` (screens and how to create a database); verify by reading back
- [ ] 8.2 `flutter analyze`, `dart format --set-exit-if-changed`, full `app`, `shared`, and `server` suites green; manual run against a dev server: create a database, add rows, drag a card, edit a cell, embed a view in a note, patch a property while typing in the body

## Definition of Done

- [ ] Every scenario in `specs/flutter-client/spec.md` and `specs/auth/spec.md` of this change has a passing widget, unit, or server test.
- [ ] `flutter analyze` and formatting clean; workspace suites green.
- [ ] Manual end-to-end check recorded in the PR description with screenshots of table, list, board, panel, and embed.
- [ ] `openspec validate add-database-views --strict` passes.
- [ ] Atomic conventional commits, tests first.
