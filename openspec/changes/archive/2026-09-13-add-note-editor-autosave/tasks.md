## 1. Controller: autosave scheduling

- [x] 1.1 Write failing tests in `app/test/src/notes/note_controller_test.dart` (mirror the existing heartbeat test setup: injected `clock`, and a new injected `autosaveScheduler` alongside the existing `scheduler`) for: (a) a debounced autosave fires ~2s after the last `setEditContent`/`setEditTitle` call and issues `PUT /notes/{id}` with the current buffers; (b) a second edit within the debounce window postpones the save — only one `PUT` fires, with the final content; (c) autosave does not fire while `mode == NoteMode.conflict`; (d) autosave only saves if still dirty when the debounce elapses (edit back to the original content → no `PUT`); (e) a conflict (409) returned from an autosave-triggered save transitions to `NoteMode.conflict` exactly as a manual save would.
- [x] 1.2 Add an `autosaveScheduler` constructor parameter to `NoteController` (`Future<void> Function(Duration)?`, default `Future<void>.delayed`), a fixed 2-second debounce constant, and `_autosaveGen`/`_scheduleAutosave()`/`_runAutosave(gen)` mirroring the existing `_heartbeatGen`/`_scheduleHeartbeat`/`_runHeartbeat` shape.
- [x] 1.3 Call `_scheduleAutosave()` at the end of both `setEditTitle` and `setEditContent`.
- [x] 1.4 `_runAutosave(gen)`: after the delay, return early if disposed, if `_autosaveGen != gen`, if `mode != NoteMode.editing`, or if `!isDirty`; otherwise call `save()`.
- [x] 1.5 Confirm all of 1.1's tests pass; run the full existing `note_controller_test.dart` suite to confirm no regressions (existing heartbeat/save/conflict tests untouched).

## 2. Controller: manual save no longer races autosave

- [x] 2.1 Write a failing test asserting that calling `save()` (or a new explicit-save entry point) does not leave a stale autosave generation able to fire a redundant second `PUT` shortly after.
- [x] 2.2 Add `cancelPendingAutosave()` (bumps `_autosaveGen`) to `NoteController`.
- [x] 2.3 `dart format`, `dart analyze` (or `flutter analyze` from `app/`) clean; confirm 2.1 passes.
- [x] 2.4 Commit: `feat(app): debounce-autosave note edits in NoteController` (combined with section 1's changes in the same commit — both landed together as one coherent controller change).

## 3. Editor: editing-status indicator replaces the lock banner

- [x] 3.1 Write failing widget tests in `app/test/src/notes/note_screen_test.dart` for a new `note.editingStatus` widget: shows "Saving…" while `mode == NoteMode.saving`; shows "Unsaved changes" while dirty and not saving; shows "Autosaved" plus a local-time-formatted `note.updatedAt` when not dirty; shows an avatar reflecting `lock!.holder`'s initial. Also assert the old `note.banner.ownLock` text/key ("You are editing (lock until...)") no longer appears.
- [x] 3.2 Implement `_EditingStatus` in `note_screen.dart` and swap it in for the `note.banner.ownLock` banner in `_buildBody`'s banner list (still only shown for `mode == NoteMode.editing && lock != null`, matching where the old banner appeared).
- [x] 3.3 Confirm 3.1 passes; check the existing lock/banner tests (`presence indicator`, `lock event from another holder`, `feedback editing shows an info banner naming the lock expiry`) — update or remove ones that assumed the old banner text, leaving the `lockedByOtherBanner`/other-viewer banner tests untouched.

## 4. Editor: flush-on-close replaces the discard prompt

- [x] 4.1 Write failing widget tests in `note_screen_test.dart`: (a) closing with a dirty buffer sends a `PUT` and then closes, with no dialog shown; (b) closing with clean buffers sends no `PUT` and closes immediately; (c) closing when the flush save returns 409 keeps the note open on the conflict view; (d) closing when the flush save fails with a plain error (not 409/423) keeps the note open, shows the existing error snackbar, and leaves the edit buffers intact; (e) closing when the flush save returns 423 (lock taken) still closes, consistent with today's lock-takeover-during-save behavior.
- [x] 4.2 Remove `_confirmDiscard()` and the "Discard changes?" `AlertDialog`. Rewrite `_close()` per design.md's flush logic: if dirty, call `controller.cancelPendingAutosave()` then `await controller.save()`; inspect the resulting state to decide whether to proceed to `exitEditing()` + `onClose()` or stay open (conflict, or a plain error) per the spec delta's four outcomes. Keep `PopScope(canPop: !state.isDirty, onPopInvokedWithResult: _onPopInvoked)` unchanged — only `_close()`'s body changes.
- [x] 4.3 Delete the now-obsolete discard-flow tests (search for `_confirmDiscard`, `note.discard.keep`, `note.discard.confirm`, `'Discard changes?'` in `note_screen_test.dart`) and confirm 4.1's new tests pass in their place.
- [x] 4.4 Check the "closing while editing" test group and the web-save-shortcut / Escape tests for any assumption of the old discard prompt; update to the new flush behavior.
- [x] 4.5 `flutter test`, `flutter analyze`, `dart format` clean for the app.
- [x] 4.6 Commit: `feat(app): flush pending edits on close instead of prompting to discard`.

## 5. Full verification

- [x] 5.1 Run `make test` (shared + server + app) and confirm everything passes.
- [x] 5.2 Run `make lint` and `dart format .` across the repo; fix any findings.
- [x] 5.3 `openspec validate add-note-editor-autosave --strict` passes.

## 6. Spec and PR

- [x] 6.1 Opened PR #165 (base `feat/note-edit-redesign`, stacked on #163 since this branch builds on its note_screen.dart changes — will need rebasing onto `main` once #163 merges), referencing the OpenSpec change and flagging the discard-prompt removal as a breaking behavior change.
- [x] 6.2 After merge, archive the OpenSpec change per the repo's archive workflow.

## Definition of Done

- All tasks above are checked off.
- `make test`, `flutter analyze`/`dart analyze`, and `dart format` are clean.
- `openspec validate --strict` passes for this change.
- Edits save automatically ~2 seconds after the user stops typing; the editor shows "Saving…" / "Unsaved changes" / "Autosaved HH:MM" instead of a lock countdown; manual Save still works as an immediate save; closing with a pending edit flushes it instead of prompting, except when the flush hits a conflict or a transient error, in which case the note stays open.
- No regressions in heartbeat, lock-acquisition, conflict-resolution, or delete/move behavior.
