## Why

A UX review of the notes list screen found that rows show only a title and
`v{version} · timestamp` — nothing to scan by — while the sidebar already
supports a nested folder tree. Meanwhile `GET /notes` already computes a
`tags` set per note (used for filtering) but never returns it, and note
content is available at the same computation point but never turned into a
preview. This change closes that gap for desktop: it's the first of two
planned changes implementing the review's notes-list findings (the second,
later change covers the mobile-specific redesign).

## What Changes

- `GET /notes` list items gain two new fields: `excerpt` (a bounded,
  markdown-stripped plain-text preview of the note body) and `tags` (the
  note's computed tag set, already used internally for filtering).
- The desktop notes-list row shows the folder path, excerpt, tag chips, and
  a relative timestamp instead of just a version/timestamp line.
- Hovering a row on wide layouts (>=700px) reveals a delete action; existing
  long-press/right-click delete keeps working everywhere, unchanged.
- The desktop toolbar gains a labelled "New note" action; the floating
  action button is removed only on wide layouts (narrow/mobile layout is
  untouched — its own redesign is a separate later change).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `notes-api`: `GET /notes` list items currently state content "SHALL NOT
  be included"; this changes to allow a bounded `excerpt` (explicitly not
  full content) and adds a `tags` field to each item.

## Impact

- **Server**: new `server/lib/src/excerpt.dart` (`computeExcerpt`);
  `NoteSummary`/`StoredNote.toSummary()` in `server/lib/src/storage.dart`
  gains `excerpt`; `routes/notes/index.dart` serializes `excerpt` and
  `tags` per item; `server/API.md` documents the new fields.
- **Shared**: `shared/lib/src/dtos.dart`'s `NoteMeta` gains `excerpt` and
  `tags`.
- **Client**: `app/lib/src/notes/notes_list_screen.dart` (row content,
  hover-to-delete) and `app/lib/src/app_router.dart` (labelled "New note"
  action, FAB only on narrow layout).
- **Spec**: `openspec/specs/notes-api/spec.md`'s "GET /notes returns
  paginated metadata" requirement and scenarios.

## Non-goals

- Mobile-specific redesign (shrunk header, bottom nav) — separate later
  change.
- Note detail, edit, search, login, or OAuth consent screens — separate
  later changes in the same review sequence.
- Persisting excerpt/tags to disk or adding any cache beyond the existing
  in-memory recompute-on-write pattern already used for tags.
