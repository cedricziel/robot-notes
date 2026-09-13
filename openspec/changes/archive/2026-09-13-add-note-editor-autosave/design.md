## Context

`NoteController.save()` (`app/lib/src/notes/note_controller.dart`) already
sends `PUT /notes/{id}` and, on success, stays in `NoteMode.editing`
(syncing `note`/`editTitle`/`editContent` to the response) rather than
exiting edit mode — it was written as a "checkpoint," not a "save and
close." It already routes `VersionConflictException` to
`NoteMode.conflict` and `LockedException` to a forced read-only banner.
Autosave is therefore a scheduling layer on top of an already-safe
`save()`, not a new save path.

The heartbeat mechanism already solves "run something on a delay, with
the ability to cancel a pending run, in a way tests can drive without
real time passing": a generation counter (`_heartbeatGen`) is bumped to
invalidate an in-flight scheduled callback, and the delay itself comes
from an injected `Future<void> Function(Duration)` (`_scheduler`) that
tests replace with a synchronous fake. See proposal.md for the full
behavior change; see the `flutter-client` spec delta for the exact
contract.

## Goals / Non-Goals

**Goals:**

- Reuse `save()` unchanged as the actual save path for both automatic
  and explicit saves — one code path, one set of conflict/lock
  behaviors.
- Make the debounce mechanism follow the heartbeat's existing
  generation-counter-over-injected-scheduler shape exactly, so it's
  testable the same way and a maintainer already familiar with the
  heartbeat code recognizes the pattern immediately.
- Never silently lose an edit: closing either persists it, or keeps the
  note open with the edit still in the buffers.

**Non-Goals:**

- A generic "debounce" utility — this is one specific use, inline in
  `NoteController`, matching the existing single-purpose style of
  `_scheduleHeartbeat`.
- Offline queueing or retry backoff for autosave — a failed autosave
  just leaves the state dirty; the next edit's debounce (or a manual
  save) tries again.

## Decisions

**A separate injected scheduler for autosave (`autosaveScheduler`),
not a reuse of the heartbeat's `_scheduler`.** Existing tests already
pass `scheduler: (_) => Completer<void>().future` everywhere to mean
"never fire the heartbeat, I'm not testing it here." If autosave shared
that same callback, every one of those tests would also silently
disable autosave, and a test that wants to fire autosave without
touching the heartbeat (or vice versa) would need a fake that
branches on the requested `Duration` to guess which timer it's for —
fragile. A second constructor parameter, defaulting to the same
`Future<void>.delayed` in production, lets tests control each
independently, same as `heartbeatInterval` already gets its own
injection point separate from the scheduler itself.

**A second generation counter (`_autosaveGen`), separate from
`_heartbeatGen`.** They cancel independently — a manual save shouldn't
stop the heartbeat, and a heartbeat failure (which already forces
read-only via `_forceReadOnly`) naturally makes further autosave ticks
no-ops because they re-check `mode == NoteMode.editing` at fire time,
without needing to explicitly bump `_autosaveGen` from the heartbeat
path.

**`setEditTitle`/`setEditContent` both call one shared
`_scheduleAutosave()`.** A single debounce covers both fields — the
mockup's "Autosaved" concept is for the note as a whole, not per-field.
Both setters already funnel through `value = value.copyWith(...)`;
`_scheduleAutosave()` is called right after, bumping `_autosaveGen` and
scheduling `_runAutosave(gen)` after the debounce `Duration` the same
way `_scheduleHeartbeat`/`_runHeartbeat` work.

**`_runAutosave` re-checks state before saving, twice.** Once for
`mode == NoteMode.editing` (not `conflict`, not `saving`, not anything
else) and once for `isDirty` — the debounce delay is long enough that
either could have changed (a conflict from a manual save mid-wait, or
the user typing back to the original text). Both checks are simple
reads of `value`, no new state needed.

**A manual save bumps `_autosaveGen` before calling `save()`.** This is
the only change to the manual-save call sites (`NoteScreen._save`,
`_keepMine`, the keyboard shortcut): they call
`controller.cancelPendingAutosave()` (a one-line method that just bumps
the generation) immediately before `save()`. Without this, a manual
save and a coincidentally-firing autosave could race into two
overlapping `PUT`s. Considered instead: making `save()` itself always
bump the generation internally — rejected, because that would also
cancel a _just-scheduled_ autosave for an edit that happened
concurrently with an unrelated manual save trigger (e.g. Cmd+S firing
while a fresh keystroke is still in its debounce window); the explicit
call site keeps the two concerns visibly separate.

**No controller-level "silent" flag for autosave's snackbar
suppression.** `_NoteScreenState._announceOutcome` is already only
called from the widget's own `_save()`/`_keepMine()` methods, not from
a listener on every controller state change. An autosave tick calls
`controller.save()` directly from inside the controller — the widget
never learns to call `_announceOutcome` for it. This falls out of the
existing architecture for free.

**The editing-status indicator is a small new stateless widget
(`_EditingStatus`), replacing the `note.banner.ownLock` `_Banner`.** It
derives everything from existing `NoteState` fields — no new state:
`mode == saving` → "Saving…"; else `isDirty` → "Unsaved changes"; else
`state.note!.updatedAt` formatted as "Autosaved HH:MM" (reusing the
existing `formatLockExpiry`-style local-time formatting already in this
file). The avatar's initial comes from `state.lock!.holder` — while
editing, the lock is always ours, so this is always our own name; no
new "who is editing" plumbing.

**`_close()` becomes a flush, not a confirm.** Replace
`_confirmDiscard()`'s `AlertDialog` with:

```
if (state.isDirty) {
  controller.cancelPendingAutosave();
  await controller.save();
}
final after = controller.value;
if (after.mode == NoteMode.conflict) return; // stay open
if (after.isDirty && after.error != null && after.mode == NoteMode.editing) {
  _announceOutcome(failed: 'Could not save'); // stay open, edits intact
  return;
}
await controller.exitEditing();
if (mounted) widget.onClose?.call();
```

(`exitEditing()` already no-ops outside `editing`/`conflict`, so the
lock-taken case — `after.mode == viewing` — falls through correctly to
`exitEditing()` returning immediately and `onClose()` firing, matching
"close proceeds after a lock takeover" from the spec delta.)
`PopScope(canPop: !state.isDirty, ...)` is unchanged — it still needs to
intercept the synchronous pop so the async flush can run first; only
the callback's body changes.

## Risks / Trade-offs

- **[Risk]** A user typing continuously never lets the 2-second debounce
  elapse, so nothing saves until they pause or close. → **Mitigation**:
  this matches how every other autosave editor behaves (Notion, Google
  Docs); closing always flushes regardless of debounce state, so the
  worst case is "not saved until you stop or leave," never "not saved
  at all."
- **[Risk]** Autosave PUTs add server load proportional to typing pauses
  rather than explicit user action. → **Mitigation**: same request
  shape and cost as today's manual save; a personal-vault-scale
  deployment (the assumption already made elsewhere in this codebase)
  doesn't make this meaningful.
- **[Risk]** Removing the discard prompt is a real behavior change a
  user could be startled by once (expecting to "cancel" edits by
  closing). → **Mitigation**: this is the explicit, agreed trade-off of
  moving to autosave — flagged as **BREAKING** in the proposal; the
  editing-status indicator ("Unsaved changes" → "Autosaved HH:MM") gives
  the user contemporaneous feedback that closing will persist, not
  discard.
