## 1. Server: excerpt computation

- [ ] 1.1 Write failing unit tests in `server/test/src/excerpt_test.dart` for `computeExcerpt`: strips headings/lists/emphasis/code spans, unwraps `[[Link|Alias]]` and `[[Link]]`, drops inline `#tags`, collapses whitespace, truncates at a word boundary with `…`, leaves short content untouched (no ellipsis), handles empty content.
- [ ] 1.2 Implement `server/lib/src/excerpt.dart` (`computeExcerpt`) to make 1.1 pass.
- [ ] 1.3 `dart analyze` and `dart format` clean for the new file.

## 2. Server: wire excerpt + tags into NoteSummary and the list API

- [ ] 2.1 Write/extend a failing test in `server/test/src/storage_test.dart` (or the nearest existing summary-focused test) asserting `StoredNote.toSummary()` populates `excerpt` via `computeExcerpt(content)`.
- [ ] 2.2 Add `excerpt` field to `NoteSummary` (`server/lib/src/storage.dart`) and compute it in `toSummary()`.
- [ ] 2.3 Write/extend a failing test in `server/test/routes/notes/index_test.dart` asserting `GET /notes` items include `excerpt` and a sorted `tags` array.
- [ ] 2.4 Update `routes/notes/index.dart`'s list-item JSON serialization to include `excerpt` and `tags` (sorted ascending, case-insensitive) — confirm 2.3 passes.
- [ ] 2.5 Update `server/API.md` to document `excerpt` and `tags` on list items.
- [ ] 2.6 `dart test` (server), `dart analyze`, `dart format` all clean.
- [ ] 2.7 Commit: `feat(server): expose excerpt and tags on GET /notes list items`.

## 3. Shared DTO

- [ ] 3.1 Write/extend a failing test in `shared/test/dtos_test.dart` asserting `NoteMeta.fromJson`/`toJson` round-trip `excerpt` and `tags`, defaulting to `''`/`const []` when absent.
- [ ] 3.2 Add `excerpt` and `tags` to `NoteMeta` (`shared/lib/src/dtos.dart`), matching `Note`'s existing `tags` handling in `fromJson`/`toJson`/`==`/`hashCode`.
- [ ] 3.3 `dart test` (shared), `dart analyze`, `dart format` clean.
- [ ] 3.4 Commit: `feat(shared): add excerpt and tags to NoteMeta`.

## 4. Client: relative time helper

- [ ] 4.1 Write a failing test for a new `formatRelativeNoteTime(DateTime, {DateTime? now})` in `app/test/src/notes/notes_list_screen_test.dart` (or wherever `formatNoteTimestamp` is tested) covering seconds/minutes/hours/days-ago boundaries.
- [ ] 4.2 Implement `formatRelativeNoteTime` in `notes_list_screen.dart` alongside (not replacing) `formatNoteTimestamp` — confirm `search_screen.dart`'s use of `formatNoteTimestamp` is untouched.

## 5. Client: redesigned desktop row

- [ ] 5.1 Write failing widget tests for `_NoteTile` (or promote it to a named, testable widget if needed) covering: folder path shown trailing the title, excerpt line rendered, a `Chip` per tag rendered, relative time shown, and version number no longer shown.
- [ ] 5.2 Update `_NoteTile` in `notes_list_screen.dart` to render path/excerpt/tags/relative-time per the design.
- [ ] 5.3 Write a failing widget test asserting the existing long-press and right-click (`onSecondaryTap`) delete menu still opens and works unchanged.
- [ ] 5.4 Write a failing widget test asserting a delete icon appears on `MouseRegion` hover at wide layout and calls the same delete flow.
- [ ] 5.5 Implement hover-to-reveal delete (`MouseRegion` + local hover state + `IconButton`) additive to the existing `MenuAnchor`, confirming 5.3 and 5.4 both pass.
- [ ] 5.6 `flutter test`, `flutter analyze`, `dart format` clean for the app.
- [ ] 5.7 Commit: `feat(app): show excerpt, tags, and path on desktop note rows`.

## 6. Client: labelled New-note action and FAB placement

- [ ] 6.1 Write a failing widget test asserting a labelled "New note" action appears in the AppBar and the FAB is absent at wide layout, while narrow layout keeps the FAB and no labelled action (unchanged from today).
- [ ] 6.2 Add the labelled "New note" AppBar action in `notes_list_screen.dart`/`app_router.dart`, gated on the existing `wide` breakpoint, reusing the current `onCreate` callback; hide the FAB only when wide.
- [ ] 6.3 `flutter test`, `flutter analyze`, `dart format` clean.
- [ ] 6.4 Commit: `feat(app): move New-note action into the toolbar on wide layouts`.

## 7. Full verification

- [ ] 7.1 Run `make test` (shared + server + app) and confirm everything passes.
- [ ] 7.2 Run `make lint` (or `dart analyze` per workspace) and `dart format .` across the repo; fix any findings.
- [ ] 7.3 Manually sanity-check in a running app (wide window: new row layout, hover-delete, toolbar button; narrow window: unchanged) if feasible in this environment.

## 8. Spec and PR

- [ ] 8.1 `openspec validate --change add-notes-list-excerpt-and-desktop-polish --strict` passes.
- [ ] 8.2 Open a PR for this change, following the repo's semantic-commit and PR conventions; reference the OpenSpec change in the PR description.
- [ ] 8.3 After merge, archive the OpenSpec change per the repo's archive workflow.

## Definition of Done

- All tasks above are checked off.
- `make test`, `dart analyze`/`flutter analyze`, and `dart format` are clean across `shared`, `server`, and `app`.
- `openspec validate --strict` passes for this change.
- Desktop notes-list rows show folder path, excerpt, tags, and relative time; hover reveals delete; a labelled "New note" action replaces the FAB on wide layouts.
- Narrow/mobile layout behavior is unchanged from before this change.
- `GET /notes` responses include `excerpt` and `tags` per item, documented in `API.md` and the `notes-api` spec.
