## 1. Swipe-to-delete on notes-list rows

- [x] 1.1 Write failing tests in `app/test/src/notes/notes_list_screen_test.dart`: swiping `notes.tile.01H.swipe` toward the leading edge opens "Delete this note?"; confirming sends `DELETE /notes/01H` and removes the row with "Note deleted"; cancelling springs the row back with no request; a failed delete keeps the row; a swipe toward the trailing edge does nothing
- [x] 1.2 Wrap `_NoteTile` in a `Dismissible` (`endToStart`, delete background, `confirmDismiss` → `_confirmDelete`, always `false`); keep the long-press menu and hover button
- [x] 1.3 `flutter analyze`, `dart format`; commit `feat(app): swipe a notes-list row to delete it`

## 2. Pull-to-refresh on the note view

- [x] 2.1 Write failing tests in `app/test/src/notes/note_controller_test.dart`: `reload()` re-issues `GET /notes/{id}` and the backlinks fetch without re-subscribing; is a no-op while editing; a failure sets `error` and keeps the note
- [x] 2.2 Add `NoteController.reload()`
- [x] 2.3 Write failing tests in `app/test/src/notes/note_screen_test.dart`: pulling `note.scroll` down shows `note.refresh`, re-fetches, and the body reflects the new content; no `RefreshIndicator` while editing
- [x] 2.4 Wrap the reading view in `RefreshIndicator` with `AlwaysScrollableScrollPhysics`
- [x] 2.5 `flutter analyze`, `dart format`; commit `feat(app): pull down on a note to re-fetch it`

## 3. Swipe up to dismiss the compact search sheet

- [x] 3.1 Write failing tests in `app/test/src/app_router_test.dart`: the compact sheet renders `search.sheet.handle`; dragging the handle up dismisses the sheet without re-fetching the list; the wide palette has no handle
- [x] 3.2 Wrap the top sheet in an upward `Dismissible` (`resizeDuration: null`) and render the handle under `SearchScreen`
- [x] 3.3 `flutter analyze`, `dart format`; commit `feat(app): swipe up to dismiss the search sheet`

## 4. Edge-swipe drawer, docs, spec

- [x] 4.1 Write a test in `notes_list_screen_test.dart` that a drag from the leading edge on a narrow layout opens `notes.sidebar.drawer`
- [x] 4.2 Add a "Touch gestures" table to `app/README.md`
- [x] 4.3 Write this change's proposal, design, tasks, and `flutter-client` spec delta; commit `docs(app): document touch gestures and specify them`

## 5. Verify

- [x] 5.1 `flutter test`, `flutter analyze`, `dart format` for the app
- [x] 5.2 `make lint` / `make fmt` at the repo root
- [x] 5.3 `openspec validate add-touch-gestures --strict` passes

## Definition of Done

- Every task above is checked off and every new scenario in `specs/flutter-client/spec.md` has a widget test that drives the gesture with a pointer.
- `flutter test`, `flutter analyze`, and `dart format` are clean in `app/`; `make lint` passes at the root.
- No action is reachable only by gesture: delete, refresh, and closing search keep their existing buttons and menus.
- `app/README.md` lists every gesture the app responds to.
