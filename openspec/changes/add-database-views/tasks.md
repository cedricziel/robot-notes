# Tasks

TDD throughout: each task names its failing widget or unit test first. Conventional commits (`feat(app): ...`, `test(app): ...`). Groups 1 and 2 are independent of each other; 3 to 7 depend on 1 and 2; group 8 depends on everything. Requires the `add-databases` server change to be merged for integration runs; unit and widget tests use a fake client.

## 1. API client and shared helpers

- [ ] 1.1 Extend `Note` with `properties` and `type`; add `listDatabases`, `getDatabase`, `createDatabase`, `updateDatabase`, `queryDatabase`, `createRow`, `patchProperties` to `RobotNotesClient` using the shared DTOs and `Routes`; failing tests with a mock HTTP client asserting method, path, headers (`If-Match` on update), and body per endpoint; implement
- [ ] 1.2 Map `400 validation_failed` with `message` into `BadRequestException` carrying the message; failing test; implement
- [ ] 1.3 Add `coveringDatabases(path, tags, definitions)` to `shared` mirroring the server rule; failing tests for folder with and without subfolders, tag, and definition exclusion; implement

## 2. Routing and server shell fallback

- [ ] 2.1 Add `GoRoute('/databases/:id')` with `view` query parsing; failing router tests for deep link, unknown view fallback rewriting the URL, setup redirect, close-to-list; implement
- [ ] 2.2 Add `/databases/*` to the server's static-web client-route fallback; failing server test that `GET /databases/01D` without auth returns `index.html`; implement

## 3. Controllers

- [ ] 3.1 `DatabasesController` (list for sidebar and embed resolution, title lookup with NFC case-insensitive match, 1 s debounced refresh on `changed`); failing tests; implement
- [ ] 3.2 `DatabaseController` (load definition, select view, query with paging, groups, optimistic patch with revert, debounced re-query on `changed`); failing tests using a fake client and fake WS stream; implement
- [ ] 3.3 `NoteController`: `properties` and covering definitions in state, `patchProperty` updating version without touching buffers, `changed` while editing refreshes properties only; failing tests for each scenario in the property panel requirement; implement

## 4. Property editors

- [ ] 4.1 `PropertyEditor` widget family for text, url, number, checkbox, date, select, multi_select, relation (reusing link autocomplete); failing widget tests per type that committing yields the right `PropertyPatch` and clearing yields `unset`; implement
- [ ] 4.2 Invalid-value styling and inline error display; widget test that a `validation_failed` result reverts and shows the message; implement

## 5. Database screen

- [ ] 5.1 Screen scaffold with title, view switcher updating the URL, New row, schema editor action; widget tests; implement
- [ ] 5.2 Table view with title column plus view properties, inline cell editing through `PropertyEditor`, invalid highlighting, infinite scroll paging; widget tests; implement
- [ ] 5.3 List view with title and property chips; widget test; implement
- [ ] 5.4 Board view with option-ordered columns, counts, No value column, drag-and-drop patching with optimistic move and revert; widget tests; implement
- [ ] 5.5 New row flow: title prompt, `createRow`, navigate to `/notes/{id}?edit=1`; widget test; implement

## 6. Schema editor and creation form

- [ ] 6.1 New-database form in the sidebar (title, folder or tag source, properties, first view) posting to `POST /databases`, inline server errors; widget tests; implement
- [ ] 6.2 Schema editor: properties CRUD with key validation and removal warning, select options, relation target; widget tests; implement
- [ ] 6.3 Schema editor: views CRUD with reorder, group_by, sort, one-level filter builder, visible properties; `PUT` with `If-Match`; 409 reload keeping edits; widget tests; implement

## 7. Note view integration

- [ ] 7.1 Property panel above the body, typed editors for declared properties, read-only rows for undeclared, collapsible with remembered state; widget tests; implement
- [ ] 7.2 Spike: confirm flutter_markdown_plus custom block syntax + element builder for a whole-line `![[...]]`; record the outcome in design.md; fall back to the segment pre-pass if unsupported
- [ ] 7.3 `DatabaseEmbed` widget resolving title and view, rendering read-only table or board limited to 50 with Show all, literal fallback, hidden in edit mode, debounced refresh; widget tests; implement
- [ ] 7.4 Sidebar Databases section with navigation; widget test; implement

## 8. Wrap-up

- [ ] 8.1 Update the `flutter-client` user-facing docs section in `README.md` (screens and how to create a database); verify by reading back
- [ ] 8.2 `flutter analyze`, `dart format --set-exit-if-changed`, full `app` and `shared` suites green; manual run against a dev server with the `add-databases` branch: create a database, add rows, drag a card, edit a cell, embed a view in a note

## Definition of Done

- [ ] Every scenario in `specs/flutter-client/spec.md` of this change has a passing widget or unit test.
- [ ] `flutter analyze` and formatting clean; workspace suites green.
- [ ] Manual end-to-end check recorded in the PR description with screenshots of table, list, board, panel, and embed.
- [ ] `openspec validate add-database-views --strict` passes.
- [ ] Atomic conventional commits, tests first.
