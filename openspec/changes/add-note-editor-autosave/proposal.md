## Why

A UX review of the note editor found that saving is entirely manual and
the only feedback while editing is a plain lock-countdown string — no
indication of who's editing or whether recent work is actually saved.
`NoteController.save()` already stays in edit mode and handles
conflicts/lock-loss robustly on every call, so autosave is a thin layer
on top of an already-safe save path, not a rewrite of it.

## What Changes

- Edits save automatically ~2 seconds after the user stops typing,
  reusing the existing `save()` method. Manual "Save" (button, Cmd/Ctrl+S)
  stays as an explicit, immediate save.
- The "You are editing (lock until HH:MM)" banner is replaced with an
  avatar + status indicator: "Saving…", "Unsaved changes", or "Autosaved
  HH:MM".
- **BREAKING** (client behavior): the "Discard changes?" confirmation on
  close is removed. Closing with a pending edit now flushes a save
  automatically instead of asking — except when the flush hits a
  conflict (stays open on the conflict view) or a transient error (stays
  open with an error message), in which case the note does not close.
- Autosave pauses during conflict resolution; resuming edits after
  resolving a conflict resumes autosave.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: "Note view supports edit, lock, and concurrency UX"
  gains automatic debounced saving. "Unsaved edits are not discarded
  without confirmation" is removed and replaced by flush-on-close
  behavior. "Save and lock outcomes are surfaced in the note view" is
  narrowed to explicit saves — autosave failures surface via the status
  indicator, not a snackbar.

## Impact

- **Client**: `app/lib/src/notes/note_controller.dart` (debounce
  scheduling, mirroring the existing heartbeat generation-counter
  pattern), `app/lib/src/notes/note_screen.dart` (editing-status
  indicator replacing the lock banner; `_close()` rewritten to flush
  instead of prompting).
- **Spec**: `openspec/specs/flutter-client/spec.md`'s edit/lock/save
  requirements.
- No server or shared-DTO changes.

## Non-goals

- Any change to the notes-list, note-detail, or formatting-toolbar/
  live-preview screens (separate PRs #159/#161/#162/#163).
- Any change to the heartbeat mechanism or lock acquire/release.
- Any change to the conflict-view UI itself — only to when autosave may
  trigger entering it.
- A "who else is viewing" indicator — this reuses the editor's own
  `lock.holder`, already their own name.
