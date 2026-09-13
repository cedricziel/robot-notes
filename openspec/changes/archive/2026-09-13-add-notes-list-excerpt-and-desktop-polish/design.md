## Context

`NoteSummary` (`server/lib/src/storage.dart`) already computes a `tags` set
in `StoredNote.toSummary()` — used internally by `MetaIndex.page`'s `tag`
filter — but it's never serialized in the `GET /notes` response. `content`
is available at that same computation point (before it's discarded), so an
excerpt is a cheap addition using the identical "recompute on every write
and on startup index rebuild, never persisted" pattern already established
for tags (see the doc comment on `StoredNote.toSummary()`).

On the client, `notes_list_screen.dart` renders `_NoteTile` from
`NoteMeta` (`shared/lib/src/dtos.dart`), which already carries `path` but
has no `excerpt`/`tags` fields — those currently only exist on the full
`Note` DTO returned by `GET /notes/{id}`.

See proposal.md for motivation and scope; see the `notes-api` spec delta
for the exact contract `excerpt`/`tags` must satisfy.

## Goals / Non-Goals

**Goals:**

- Compute `excerpt` the same way `tags` already works: derived, recomputed
  on read, never persisted or cached separately.
- Keep the change additive on the client: no existing delete affordance
  (long-press, right-click) regresses; narrow/mobile layout is untouched.

**Non-Goals:**

- Full markdown-to-plain-text fidelity (e.g. tables, nested lists, code
  blocks) — light stripping of the common constructs likely to appear in a
  personal note's opening lines is enough for a preview.
- Any mobile layout change (separate later change).

## Decisions

**Excerpt computation lives in a new `server/lib/src/excerpt.dart`,
mirroring `tags.dart`'s shape.** A pure function `String
computeExcerpt(String content, {int maxLength = 140})` — not a class,
matching `computeTags`'s style. Alternative considered: fold it into
`tags.dart` as a second export — rejected, `tags.dart`'s name and doc
comments are tag-specific and mixing concerns there would blur both.

**Stripping order:** strip fenced/inline code spans first (their contents
should not be treated as markdown), then unwrap `[[Link|Alias]]` →
`Alias` and `[[Link]]` → `Link`, then strip leading heading (`#{1,6} `)
and list markers (`-`, `*`, `+`, or `\d+.` at line start), then strip
emphasis markers (`**`, `*`, `_`, `` ` ``), then drop inline `#tag` tokens
(reuse `_inlineTagPattern`-equivalent matching from `tags.dart` — export
or duplicate the regex; duplicating is fine here since the two call sites
serve different purposes and `tags.dart` isn't a shared-utility module),
then collapse all whitespace/newlines to single spaces and trim. Finally
truncate to `maxLength` at the last word boundary at or before the limit,
appending `…` — unless the stripped text is already within the limit, in
which case no ellipsis is added.

**Tags serialization order:** `NoteSummary.tags` is a `Set<String>`
without inherent order. Serialize as a sorted list (case-insensitive
ascending) for deterministic API responses and stable widget tests,
rather than insertion/hash order.

**Client relative-time formatting is a new function, not a replacement.**
`formatNoteTimestamp` (absolute `YYYY-MM-DD HH:MM`) is reused by
`search_screen.dart` and must keep working unchanged. Add a sibling
`formatRelativeNoteTime(DateTime, {DateTime? now})` (test-injectable
`now`, matching the existing testable-timestamp pattern) used only by the
redesigned row.

**Tag chips on the row reuse the existing `Chip` visual style from
`_TagChips` in `note_screen.dart`** (small, low-emphasis) rather than
introducing a new shared widget — the row's chips are read-only (no tap
action needed here, unlike the detail screen's `ActionChip`), so a
lighter inline `Chip` per tag is simplest; extracting a shared widget for
two call sites with different interaction models isn't warranted yet.

**Hover-delete uses `MouseRegion` + local hover state per row, additive
to the existing `MenuAnchor`.** The `MenuAnchor`'s long-press/
right-click-triggered menu stays exactly as implemented; the hover
affordance is a separate, purely visual `IconButton` that appears when
`MouseRegion.onEnter` fires and calls the same `onDelete` callback
`_confirmDelete` already provides. No behavior change for touch or
keyboard users.

**FAB removal is layout-conditional, not a separate widget tree.** Reuse
the existing `LayoutBuilder`'s `wide` boolean (already computed for the
sidebar breakpoint) to decide both "show sidebar inline" and "show FAB
vs. AppBar button" — one breakpoint, one source of truth, since the
proposal ties both to the same 700px threshold.

## Risks / Trade-offs

- **[Risk]** Markdown stripping is necessarily heuristic; some content
  could still render awkwardly (e.g. an unclosed emphasis marker leaving
  a stray `*`). → **Mitigation**: unit-test the common constructs
  explicitly; accept imperfect edge cases for a preview string, not
  loud enough to warrant a full markdown parser dependency for this.
- **[Risk]** Sorting tags for the API response is a small behavior choice
  a client integration might not expect. → **Mitigation**: called out
  explicitly in the spec delta scenario and `API.md`, so it's documented
  contract, not incidental.
- **[Risk]** `excerpt` computation runs on every list-triggering write and
  full index rebuild, same cost class as the existing `tags` computation.
  → **Mitigation**: no new cost profile introduced; existing personal-vault
  scale assumption (see `MetaIndex` doc comments) already covers this.
