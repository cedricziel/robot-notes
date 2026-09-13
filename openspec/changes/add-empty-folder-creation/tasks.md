## 1. Marker file and startup scan

- [ ] 1.1 Write a failing test asserting the startup scan discovers a `.folder` marker file under `<data-dir>/content/<path>/.folder` and registers `<path>` as a known-empty folder, distinct from note-derived paths
- [ ] 1.2 Write a failing test asserting a marker file is excluded from `Storage.list()` / note enumeration, `GET /search`, link parsing, and tag computation (it is never treated as a note)
- [ ] 1.3 Implement the marker-file scan alongside the existing `content/**/*.md` walk (wherever that walk currently lives — `storage.dart`'s startup scan per design.md), populating a new small `Set<String>` of marker-only folder paths exposed from `MetaIndex` (or `Storage`, matching wherever `MetaIndex` already gets its data); run 1.1–1.2 green
- [ ] 1.4 Write a failing test: a folder with both a marker file and a note (marker written before the note existed) keeps the marker on disk after the note is created, and the folder is not double-counted
- [ ] 1.5 Verify 1.4 passes with the implementation from 1.3 (should require no extra code per design.md's "marker survives" decision — write the test to confirm, add code only if it fails)
- [ ] 1.6 Commit: `feat(server): scan for empty-folder marker files on startup`

## 2. POST /notes/tree

- [ ] 2.1 Write a failing route test: `POST /notes/tree` with `{"path": "Ideas"}` on a fresh vault returns 201 with `{"path": "Ideas", "note_count": 0}`, creates the directory, and writes a `.folder` marker in it
- [ ] 2.2 Write a failing route test: a subsequent `GET /notes/tree` after 2.1 lists `Ideas` with `note_count: 0`
- [ ] 2.3 Write a failing route test: `POST /notes/tree` with a nested path (`"Projects/Gamma/Sub"`) whose intermediates don't exist creates the full chain and returns 201 for the full path
- [ ] 2.4 Write a failing route test: `POST /notes/tree` for a path that already has notes returns 200 with the existing `note_count` and writes no marker file
- [ ] 2.5 Write a failing route test: `POST /notes/tree` for a path that already has a marker-only folder returns 200 with `note_count: 0` and does not create a second marker or error
- [ ] 2.6 Write a failing route test: `POST /notes/tree` with a case-only-different path (`"ideas"` when `Ideas` already exists) resolves to the existing folder (per `note_path.dart`'s `collisionKey`), returning 200 for the existing folder rather than creating a new one
- [ ] 2.7 Write a failing route test: `POST /notes/tree` with `{"path": ""}` returns 400
- [ ] 2.8 Implement the `POST` branch in `server/routes/notes/tree.dart`: sanitize/normalize the path via the existing `note_path.dart` helpers, reuse the existing per-target-path lock used by note moves (per `storage.dart`) to serialize concurrent creates at the same path, create the directory, conditionally write the marker (per design.md's "only when no notes exist yet" rule), and update the in-memory empty-folder set from task group 1; run 2.1–2.7 green
- [ ] 2.9 Update the `## Requirements` scenarios already covered by 1.4/1.5 are storage-level; confirm no regression in the existing `GET /notes/tree` route tests (folder-with-notes listing, folder-with-no-marker-and-no-notes omitted)
- [ ] 2.10 Commit: `feat(server): add POST /notes/tree to create empty folders`

## 3. MCP create_folder tool

- [ ] 3.1 Write a failing test: `tools/list` includes `create_folder` with `inputSchema.required == ["path"]`, alongside the existing nine tools (catalog size 9 → 10; update any hard-coded catalog-size assertions in existing MCP tests)
- [ ] 3.2 Write a failing test: `create_folder` with `path: "Ideas"` on a fresh vault returns `structuredContent == {"path": "Ideas", "note_count": 0}` with no error
- [ ] 3.3 Write a failing test: `create_folder` called twice with the same `path` succeeds both times with identical `structuredContent`
- [ ] 3.4 Write a failing test: `create_folder` with `path: ""` returns `isError: true` with `structuredContent.error == "validation_failed"`
- [ ] 3.5 Implement the `create_folder` tool definition and handler in `server/lib/src/mcp/tools.dart`, delegating to the same underlying folder-creation logic as `POST /notes/tree` (per design.md, no duplicated implementation); run 3.1–3.4 green
- [ ] 3.6 Commit: `feat(server): add create_folder MCP tool`

## 4. Flutter: "New folder" sidebar action

- [ ] 4.1 Write a failing test in `app/lib/src/api/api_client.dart`'s test suite: a new `createFolder(path)` client method POSTs `/notes/tree` with the given path and returns the decoded `{path, note_count}`
- [ ] 4.2 Implement `RobotNotesClient.createFolder()`; run 4.1 green
- [ ] 4.3 Write a failing widget test: `folder_tree_sidebar.dart` renders a "New folder" action (e.g. an icon button in the sidebar header)
- [ ] 4.4 Write a failing widget test: tapping "New folder", entering a path in the resulting prompt, and confirming calls `createFolder` with that path and then refreshes the tree (reuses the existing tree-controller refresh path from `add-vault-structure`'s live-update wiring)
- [ ] 4.5 Write a failing widget test: a failed `createFolder` call shows the server's error message via the existing `describeError()` helper (not a raw/null message) and leaves the prompt open rather than dismissing it
- [ ] 4.6 Implement the "New folder" action, prompt dialog, and error handling in `folder_tree_sidebar.dart` / `folder_tree_controller.dart`; run 4.3–4.5 green
- [ ] 4.7 Commit: `feat(app): add a "New folder" action to the sidebar`

## 5. Flutter: FAB menu for note + folder creation

- [ ] 5.1 Write a failing widget test: tapping the notes list FAB shows a menu with "New note" and "New folder" entries instead of creating a note immediately
- [ ] 5.2 Write a failing widget test: choosing "New note" while a folder is selected (`NotesListState.selectedPath == "Projects/Alpha"`) creates the note with `path: "Projects/Alpha"` and navigates to it in edit mode
- [ ] 5.3 Write a failing widget test: choosing "New note" with no folder selected creates the note with `path: ""`
- [ ] 5.4 Write a failing widget test: choosing "New folder" opens a prompt pre-filled with the currently selected folder path, and confirming calls `createFolder` with the (possibly edited) path, then refreshes the tree/list
- [ ] 5.5 Write a failing widget test: a failed "New folder" submission from the FAB shows the server's error message via `describeError()` and leaves the prompt open (mirrors 4.5)
- [ ] 5.6 Implement the FAB menu (reusing the existing `MenuAnchor`/`PopupMenuButton` pattern already used elsewhere in the app), the folder-aware note-create call, and the "New folder" prompt reusing the dialog built in task group 4; run 5.1–5.5 green
- [ ] 5.7 Commit: `feat(app): turn the notes list FAB into a New note / New folder menu`

## 6. Docs and end-to-end check

- [ ] 6.1 Run the full server and app test suites; fix any regressions
- [ ] 6.2 Update `server/STORAGE.md` to document the `.folder` marker file convention alongside the existing `<id>.md`/frontmatter documentation
- [ ] 6.3 Update `server/API.md` to document `POST /notes/tree`
- [ ] 6.4 Manually verify against a running server + app: create an empty folder from the sidebar and from the FAB, confirm both appear with a zero count, restart the server, confirm it's still listed; create a note inside it and confirm the marker file and note coexist on disk
- [ ] 6.5 Commit: `docs(server): document the empty-folder marker file and POST /notes/tree`

## Definition of Done

- All tasks above checked off, each with its own green test run and its own commit
- `openspec validate add-empty-folder-creation --strict` passes
- Full server (`dart test`) and Flutter (`flutter test`) suites pass
- A restart with an explicitly-created empty folder on disk still reports that folder from `GET /notes/tree`
- No `TODO`/`FIXME` left from this change in touched files
