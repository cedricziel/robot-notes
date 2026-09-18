# Tasks

TDD throughout: each task names its failing widget or unit test first. Conventional commits (`feat(app): ...`, `test(app): ...`). Dependencies: 1.1 (the spike) comes first and is blocking. Group 1 is otherwise independent. Group 2 depends on 1. Group 3 depends on 1. Groups 4 to 7 depend on 1 to 3. Group 8 depends on everything. Requires the `add-databases` server change (including its shared `coveringDatabases` helper and DTOs) to be merged; unit and widget tests use a fake client.

## 1. Spike, API client, and error mapping

- [x] 1.1 Spike: confirm flutter_markdown_plus custom `BlockSyntax` plus `MarkdownElementBuilder` can claim a whole line `![[...]]` without affecting inline text; record the outcome in design.md; if unsupported, switch the design to the segment pre-pass before any other task starts — confirmed supported; spike kept as a real test at `app/test/src/databases/database_embed_syntax_spike_test.dart` backed by `app/lib/src/databases/database_embed_syntax.dart`, which task 7.2 builds on
- [x] 1.2 Extend `Note` with `properties` and `type`; add `listDatabases`, `getDatabase`, `createDatabase`, `updateDatabase`, `queryDatabase`, `createRow`, `patchProperties` to `RobotNotesClient` using the shared DTOs and `Routes`; failing tests with a mock HTTP client asserting method, path, headers (`If-Match` on update), and body per endpoint; implement — `Note` already carried `properties`/`type` from the merged `add-databases` shared DTOs, so only the `RobotNotesClient` methods and their tests were added
- [x] 1.3 Map 409 `version_conflict` without `current` to `VersionConflictException` with a null `current`; regression test that 400 `validation_failed` still yields `BadRequestException` with the message; implement
- [x] 1.4 Extract title search from `NoteController.searchLinkTitles` into a standalone `TitleSearchService` usable without a note, with an optional database restriction via `queryDatabase`; failing tests; implement and re-point `NoteController` — `queryDatabase` doesn't exist yet (blocked on 1.2, out of scope for this agent), so `databaseRestriction` is a plain `Future<List<String>> Function(String query)?` hook for now; callers can wire it to `queryDatabase` once it lands — follow-up done: added `TitleSearchService.forDatabase(api, databaseId)`, a factory that builds `databaseRestriction` from `RobotNotesClient.queryDatabase` (title `contains` filter); no existing caller was repointed to it yet since the relation picker (task 4.1) that will use it is still unimplemented

## 2. Routing and server shell fallback

- [x] 2.1 Add `GoRoute('/databases/:id')` inside the existing shell with `view` query parsing; failing router tests for deep link, setup redirect, close-to-list, and the list pane scoped to the source folder; unknown-view fallback rewriting the URL is tested in 5.1 once the controller exists; implement — added a placeholder `DatabaseScreen(id, viewName, onClose)` stub in `app/lib/src/databases/database_screen.dart` and a `_DatabasePage` shell page mirroring `_NotePage`'s close behavior; list-pane scoping to the source folder needs the cached full definition from `GET /databases/{id}` (`DatabasesController`, group 3, not built yet), so it is left as a `TODO(add-database-views task 5.1+)` hook in `app_router.dart` — the list pane currently shows its normal unscoped selection while a database screen is open, covered by a router test that documents this and will need updating once group 3 lands
- [x] 2.2 Add `GET /databases/{id}` to the server's dual-use path check with `Vary: Accept, Authorization`, keeping bare `GET /databases` API-only; failing server tests: browser-style request gets `index.html`, non-browser gets 401, bare list gets 401; implement

## 3. Controllers

- [x] 3.1 `DatabasesController`: list for sidebar and embed resolution, title lookup with NFC case-insensitive match, cache of full definitions filled on demand, 1 s debounced refresh and cache invalidation on any `changed`; failing tests; implement — added `unorm_dart` as an `app` dependency (already used server-side) for NFC normalization
- [x] 3.2 `DatabaseController`: load definition from the cache, select view, table and list paging, per-column board paging with filter override, groups, optimistic patch with revert, "left the view" detection with undo, debounced re-query on `changed`, loading, empty, error, and not-found states; failing tests using a fake client and fake WS stream; implement
- [x] 3.3 `NoteController`: `properties` and covering definitions in state (via shared `coveringDatabases` and the definition cache), `patchProperty` serialized with autosave (cancel, wait for in-flight save, adopt returned version, re-arm), `changed` while editing refreshes displayed properties only and never the version; failing tests for every panel scenario including "patch during an armed autosave causes no conflict"; implement — took the definition cache as an injected `Future<List<DatabaseDefinition>> Function()? allDatabaseDefinitions` callback rather than a direct `DatabasesController` dependency, matching the existing `TitleSearchService` injection style; group 7's widget wiring supplies one backed by `DatabasesController`

## 4. Property editors

- [x] 4.1 `PropertyEditor` widget family for text, url, number, checkbox, date, select, multi_select, relation (multi-value list via `TitleSearchService`, restricted by `database` when declared); failing widget tests per type that committing yields the right `PropertyPatch` and clearing yields `unset`; implement — added at `app/lib/src/databases/property_editor.dart`; the widget takes an explicit `propertyKey` (not in the design.md sketch's `PropertyEditor(type, value, onCommit)`) since it must build the `{key: value}` map itself; `onCommit` is `Future<String?> Function(PropertyPatch)` (message or null) rather than a bare callback, so 4.3's revert-and-show-message behavior can live in the same widget instead of the caller
- [x] 4.2 Read-only renderers for built-ins (`tags` chips, relative dates, path text) and for values the editor cannot represent; widget tests; implement — added `app/lib/src/databases/property_value_view.dart` (`PropertyValueView.tags/.relativeTime/.path/.unrepresentable`), reusing the existing `formatRelativeNoteTime`/`formatNoteTimestamp` from `app/lib/src/format/note_time.dart`
- [x] 4.3 Invalid-value styling and inline error display; widget test that a `validation_failed` result reverts and shows the message; implement — folded into `PropertyEditor` (see 4.1): an `invalid` flag styles a server-flagged value up front, and any `onCommit` rejection reverts the optimistic value and shows the message via a `Key('property_editor.error')` `Text`

## 5. Database screen

- [x] 5.1 Screen scaffold with title, view switcher updating the URL (including unknown-view fallback), New row, schema editor action, loading, empty, error, and not-found states; widget tests; implement — group 4 (`PropertyEditor`) was not merged yet, so table cells (5.2) use a placeholder `DatabaseCellEditor` (see its note below) instead; the router's `_DatabasePage` stub was replaced with a `DatabaseRoute` widget (in `database_screen.dart`) that owns the `DatabasesController`/`DatabaseController` pair and wires the URL rewrite via `onViewChanged`
- [x] 5.2 Table view with title column plus view keys (properties and built-ins), inline cell editing through `PropertyEditor`, invalid highlighting, infinite scroll paging, left-the-view notice with undo; widget tests; implement — **follow-up for group 4**: cell editing goes through `DatabaseCellEditor` (`app/lib/src/databases/database_cell_editor.dart`), a placeholder that opens a single free-text field and commits `PropertyPatchCommit = void Function(String propertyKey, PropertyPatch patch)`, exactly the signature the real typed `PropertyEditor(type, value, onCommit)` should expose once task 4.1 lands — swapping it in is a one-widget change inside `_RowWidget` in `database_table_view.dart`
- [x] 5.3 List view with title and property chips; widget test; implement
- [x] 5.4 Board view with option-ordered columns, counts, No value column, per-column paging with Load more, drag-and-drop patching with optimistic move and revert; widget tests; implement — uses `LongPressDraggable`/`DragTarget` per design.md; a column's emptiness for the screen's overall "no rows yet" state is judged by `count == 0` across all columns rather than by loaded `items`, so a column whose first page hasn't arrived yet doesn't wrongly read as empty
- [x] 5.5 New row flow: title prompt, `createRow`, navigate to `/notes/{id}?edit=1`; widget test; implement — added `DatabaseController.createRow` (small addition to the group-3 controller, task 3.2, kept minimal) so the write stays behind the controller like every other mutation it makes

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
