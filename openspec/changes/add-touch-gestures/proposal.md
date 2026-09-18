## Why

On a phone the client is mostly reachable through taps on chrome: deleting a note means a long-press and a menu, refreshing an open note means closing and reopening it, and the only way out of the compact search sheet is its close button or the scrim. The adaptive shell gave the app phone-sized layouts; this change gives those layouts the gestures people expect from them, so the common actions are one swipe away instead of two taps.

## What Changes

- Swiping a notes-list row from the trailing edge toward the leading edge reveals a delete background and, past the threshold, runs the same confirmation dialog the long-press menu uses. Cancelling springs the row back; confirming sends `DELETE /notes/{id}` and removes the row. The long-press/right-click menu and the wide-layout hover button stay.
- Pulling down on the note view while reading re-fetches the note (`GET /notes/{id}`) and its backlinks, so a phone without a live WebSocket can still pick up an agent's edits. Pull-to-refresh is not offered while editing, resolving a conflict, or acquiring the lock.
- The compact search sheet grows a grab handle along its bottom edge and dismisses on a swipe up over the handle or the header, in addition to the existing close button and scrim tap. Swiping over the results list still scrolls the list.
- On narrow layouts a drag from the leading screen edge opens the folder drawer; this already worked through the `Scaffold` default and is now specified and tested rather than incidental.
- `app/README.md` gains a "Touch gestures" table beside the keyboard shortcuts table.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: the delete-from-list requirement gains a swipe entry point; the note view gains a pull-to-refresh requirement; the search requirement gains the swipe-to-dismiss scenario for the compact sheet; the sidebar requirement gains the edge-swipe scenario.

## Impact

- `app/lib/src/notes/notes_list_screen.dart`: each `_NoteTile` is wrapped in a `Dismissible` whose `confirmDismiss` calls the existing `_confirmDelete`.
- `app/lib/src/notes/note_controller.dart`: new `reload()` that re-fetches the note and backlinks without re-subscribing.
- `app/lib/src/notes/note_screen.dart`: the reading view's scrollable sits inside a `RefreshIndicator`.
- `app/lib/src/app_router.dart`: the compact search sheet is wrapped in an upward `Dismissible` and renders a grab handle.
- `openspec/specs/flutter-client/spec.md` via this change's delta; `app/README.md`.

## Non-goals

- No swipe-to-move or swipe-to-archive on list rows; the only destructive swipe is delete, and it always confirms.
- No swipe between adjacent notes in the note view, and no swipe to toggle the editor preview: horizontal drags inside text fields belong to selection.
- No change to the wide-layout search palette (a centered dialog has no edge to swipe from).
- No change to request shapes, the lock protocol, or autosave.
