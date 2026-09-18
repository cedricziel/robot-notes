## Context

`NotesListScreen` renders each row as a `ListTile` inside a `MenuAnchor` whose builder wraps it in a `GestureDetector` for long-press and right-click; on wide layouts a `MouseRegion` adds a hover-revealed delete button. `_confirmDelete(id)` owns the confirmation dialog, the `NotesListController.delete` call, and the "Note deleted" snackbar. `NoteScreen` renders the reading view as a `SingleChildScrollView` keyed `note.scroll`; `NoteController.open()` fetches the note once and subscribes to its realtime events. The compact search overlay is a `showGeneralDialog` top sheet built in `app_router.dart`; the narrow notes list already opens its drawer via the bottom nav and, through the `Scaffold` default, an edge drag. See proposal.md - Why.

## Goals / Non-Goals

**Goals:**

- Every gesture routes into an existing action so the confirmation, error, and snackbar behaviour is identical whichever way the action was reached.
- Gestures are additive: nothing the toolbar, menus, or keyboard can do today becomes gesture-only.
- Each gesture has a widget test that drives it with a pointer, not by calling the callback.

**Non-Goals:**

- Swipe-to-move, swipe between notes, swipe to toggle preview (see proposal.md).
- Any gesture on the wide-layout search palette or the account sheet.

## Decisions

- **`Dismissible` per row, `endToStart` only, always answering `false` from `confirmDismiss`.** `confirmDismiss` awaits the existing `_confirmDelete(id)` and returns `false` regardless of outcome. When the user cancels, or the server rejects the delete, the row springs back; when the delete succeeds the controller has already removed the row from `state.items`, so the `Dismissible` is gone before it could animate. Returning `true` would instead require the row to leave the tree in `onDismissed`, duplicating the controller's removal and racing it. `Dismissible` guards its post-confirm animation on `mounted`, so an unmounted row is safe. `startToEnd` is disabled so a right-swipe does nothing rather than hinting at an action that doesn't exist. Alternative considered: `flutter_slidable` — a dependency for one action.
- **Swipe is enabled on every layout, not only `narrow`.** The three-pane shell pins the list pane to `NotesListLayout.wide` even on a 1200px tablet, which is exactly where a swipe is wanted. A mouse drag on a desktop row also works and is harmless; trackpad two-finger scrolling is a scroll event, not a drag, so it doesn't trigger it.
- **`NoteController.reload()` rather than calling `open()` again.** `open()` calls `_onSubscribe`, which would re-send the WebSocket subscribe; `reload()` re-issues only `GET /notes/{id}` and the backlinks fetch, keeps `mode` at `viewing`, and is a no-op in any other mode so a pull can never clobber edit buffers or an in-flight lock acquisition. Errors land in `NoteState.error` like `open()`'s, and the previous note stays on screen.
- **`RefreshIndicator` wraps only the reading view.** The editor and conflict views are not wrapped, so there is no indicator to pull while editing; the reading view's `SingleChildScrollView` gets `AlwaysScrollableScrollPhysics` so a short note can still be pulled.
- **Search sheet: an upward `Dismissible` with `resizeDuration: null` plus a grab handle.** `onDismissed` pops the dialog route, the same path as the close button, so the `NotesSearchController` is disposed in the existing `finally`. `resizeDuration: null` skips the collapse animation and its "still in the tree" assertion, since the route's own exit transition removes the sheet. The results `ListView` wins the vertical-drag arena where it is under the finger, so swiping over results scrolls; the header and the handle have no scrollable, so swipes there dismiss. The handle (`search.sheet.handle`) is a Material-style pill at the sheet's bottom edge, which is where the sheet ends and the scrim begins. Alternative considered: `DraggableScrollableSheet` — it anchors to the bottom and would need the search content refactored around its scroll controller.
- **Edge drag opens the drawer via the `Scaffold` default.** No code change; the spec scenario and test pin `drawerEnableOpenDragGesture` staying `true` on narrow layouts so a future refactor can't drop it silently.

## Risks / Trade-offs

- [Horizontal swipe on a row competes with the three-pane shell's `ResizablePanel` drag handle] → The handle sits between the sidebar and the list, outside every row's hit box; a drag that starts on a row never reaches it.
- [`Dismissible` claims horizontal drags, so a horizontal scroll inside a row is impossible] → Rows have no horizontal scrollable today; titles and excerpts ellipsize.
- [A pull-to-refresh that lands while another actor edits could show a newer version than the one the user last read] → That is the point; the metadata line shows the new version and updated time, and the reader wasn't editing.
- [Users who swipe over the search results expecting dismissal get a scroll instead] → The grab handle is visible at the bottom edge as the affordance; the scrim and close button remain.
