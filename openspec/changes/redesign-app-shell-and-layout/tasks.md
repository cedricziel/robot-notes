## 1. Shared foundations

- [x] 1.1 Write failing tests for `Breakpoints.classify` at 599/600/839/840/1199/1200 and for the `WindowSizeClass` `>=`/`<` operators (`app/test/src/layout/breakpoints_test.dart`)
- [x] 1.2 Add `app/lib/src/layout/breakpoints.dart`: `WindowSizeClass {compact, medium, expanded, large}`, `Breakpoints.classify/of/fromConstraints`, `PaneSizes` (sidebar 260/200–420, list pane 380, reading column 760, editor split 1400)
- [x] 1.3 Write failing tests for `StatusStrip` (tone colours come from the `ColorScheme`, `dense`/`rounded`/`action` variants), `EmptyState`, and `ResizablePanel` (drag handle `panel.resizeHandle` clamps to min/max) in `app/test/src/widgets/`
- [x] 1.4 Add `StatusStrip`, `EmptyState`, `ResizablePanel`; make `ErrorStrip` a preset over `StatusStrip`
- [x] 1.5 Write failing tests for `formatRelativeNoteTime`/`formatClockTime`/`formatNoteDate` boundaries in `app/test/src/format/note_time_test.dart`
- [x] 1.6 Move the time formatters into `app/lib/src/format/note_time.dart`; keep `notes_list_screen.dart` re-exporting `formatNoteTimestamp`/`formatRelativeNoteTime`
- [x] 1.7 Write a failing `app/test/theme_test.dart` asserting both brightnesses come from one seed, adaptive density, and a flat app bar; add `AppTheme.light()/dark()` and `AppTheme.markdown(context)`, wire them in `main.dart`
- [x] 1.8 `flutter analyze`, `dart format` clean; commit `refactor(app): add shared layout, theme, status-strip, and time-format foundations`

## 2. Notes list

- [x] 2.1 Update `notes_list_screen_test.dart` to drive layouts with 800 (wide) / 400 (narrow) instead of the old 700 constant, and with an explicit `layout: NotesListLayout.wide`
- [x] 2.2 Write failing tests: wide toolbar renders "New note" (`notes.create.toolbar`), upload (`notes.create.upload.toolbar`), search (`shell.search`), refresh (`shell.refresh`), and account (`shell.account`) in that order; no FAB at wide; no toolbar at narrow
- [x] 2.3 Remove `appBarActions`; render the toolbar inside the screen from `onCreateNote`/`onUploadFile`/`onSearch`/`onAccount`; add `NotesListLayout` and `selectedNoteId`
- [x] 2.4 Write failing tests: title (`notes.title`) reads "Notes" unscoped, the folder's last segment when scoped, "Root" for `''`; folder chip (`notes.filter.folder`) clears via `notes.filter.folder.clear` → `selectFolder(null)`
- [x] 2.5 Add the folder chip beside the tag chip and derive the title from `selectedPath`
- [x] 2.6 Write failing tests: row tags are plain `#tag` text (no `Chip`), the path sits in the metadata line, and is hidden when the list is scoped to that folder
- [x] 2.7 Rework `_NoteTile`: tag labels, `path · relative time` subtitle, path hidden when scoped, `ListTile.selected` for `selectedNoteId`
- [x] 2.8 Write failing tests for the three empty states (`notes.empty`, `notes.empty.create`, `notes.empty.clearFilter`) and that loading/error do not show one
- [x] 2.9 Render `EmptyState` when the first page loaded empty without error
- [x] 2.10 Write a failing test that dragging `panel.resizeHandle` changes the wide sidebar width; wrap the inline sidebar (`notes.sidebar.wide`) in `ResizablePanel`
- [x] 2.11 `flutter analyze`, `dart format`; commit `feat(app): notes list toolbar, folder scope chip, empty states, resizable sidebar`

## 3. Note view

- [x] 3.1 Write failing tests: `presentation: page` shows a back arrow, `pane` shows a close icon, both keyed `note.close` and both run the same close flow
- [x] 3.2 Add `NotePresentation {page, pane}` and switch the leading icon on it
- [x] 3.3 Write failing tests: metadata, body, tags, and backlinks share one scrollable and one left edge; backlinks are not pinned at the bottom
- [x] 3.4 Rebuild the reading view as a single capped column (`PaneSizes.readingColumn`) containing `note.metadata`, `note.body`, `note.tags`, `note.backlinks`
- [x] 3.5 Write failing tests: `note.presence` renders stacked avatars, collapses beyond three viewers, and always carries a tooltip listing every name
- [x] 3.6 Replace the inline presence text with stacked avatars + tooltip
- [x] 3.7 Write failing tests: double-tap on `note.body` and Cmd/Ctrl+E call the same lock path as `note.edit`; both are no-ops while another actor holds the lock
- [x] 3.8 Wire the double-tap recogniser and the Cmd/Ctrl+E shortcut to `_edit`
- [x] 3.9 Write failing tests: editor fields are borderless and capped to the reading width; preview (`note.editor.preview`) is on by default at 800 wide and off at 400; the toggle flips it; body and preview use `AppTheme.markdown`
- [x] 3.10 Restyle the editor and add the preview toggle with its size-class default; delegate `formatLockExpiry` to `formatClockTime`
- [x] 3.11 Move the lock, locked-by-other, conflict, and editing-status banners onto `StatusStrip` (keys unchanged)
- [x] 3.12 `flutter analyze`, `dart format`; commit `feat(app): document-style note view with reading column, presence avatars, and quick edit entry`

## 4. Search, setup, and connection banner

- [x] 4.1 Write failing tests: `SearchScreen` renders no `Scaffold`/`AppBar`; header shows `search.input`, `search.clear` (with text), and `search.close` only when `onClose` is set; it lays out inside a 640-wide `Dialog` and a full-width top sheet
- [x] 4.2 Replace the `Scaffold` with a `Material` surface and header row; add `onClose`; use `EmptyState` for the hint and no-match states
- [x] 4.3 Write failing tests: `ConnectionBanner` renders a dense `StatusStrip` (`connection.banner`) inside a top-only `SafeArea` when not connected and a bare `SizedBox.shrink` when connected
- [x] 4.4 Port `ConnectionBanner` to `StatusStrip`
- [x] 4.5 Write failing tests: setup failures render in an error-tone `StatusStrip`; `setup.reachability.ok` uses `colorScheme.primary`, not a hard-coded green
- [x] 4.6 Replace `_ErrorBanner` with `StatusStrip` and the reachability colour with the scheme colour
- [x] 4.7 `flutter analyze`, `dart format`; commit `feat(app): search as a chrome-less surface, status strips in setup and connection banner`

## 5. Router, shell, account, shortcuts

- [x] 5.1 Write failing tests in `app_router_test.dart`: at 1400 wide `/` shows sidebar, list, and `shell.detail.empty`; `/notes/01H` shows the note in the third pane with row `01H` selected; at 800 wide `/notes/01H` is a full-screen page
- [x] 5.2 Add the `ShellRoute` over `/` and `/notes/:id`; build the three-pane `Row` at `WindowSizeClass.large` and pass the routed child through below it; `go` at large, `push` below
- [x] 5.3 Write failing tests: `onAccount` opens `account.sheet` (bottom sheet at 400, dialog at 800) showing `account.server`, `account.actor`, `account.connection`; `account.disconnect` runs the confirm dialog then `onReset`; `shell.reset` no longer exists
- [x] 5.4 Add `AppSession.connection` and the account surface; remove the toolbar logout button
- [x] 5.5 Write failing tests: Cmd/Ctrl+N creates a note in the selected folder; Cmd/Ctrl+K and Cmd/Ctrl+Shift+F open the search overlay
- [x] 5.6 Wrap the shell in `Shortcuts`/`Actions` for the three app-level bindings
- [x] 5.7 Write failing tests: search opens as a top sheet at 400 and a centered `Dialog` (≤640 wide) at 800, with `search.close` dismissing it
- [x] 5.8 Present the overlay by size class and pass `onClose` to `SearchScreen`
- [x] 5.9 Write a failing test that the routed child's `AppBar` is not inset a second time while `connection.banner` shows; wrap the child in `MediaQuery.removePadding(removeTop: true)` while visible
- [x] 5.10 Update `note_route_test.dart`, `create_note_workflow_test.dart`, `upload_file_workflow_test.dart`, `widget_test.dart` for the new API (no `appBarActions`, `NotesListLayout`, `NotePresentation`)
- [x] 5.11 `flutter analyze`, `dart format`; commit `feat(app): three-pane shell, account surface, and app-level shortcuts`

## 6. Docs and spec

- [x] 6.1 Replace the Flutter template `app/README.md` with what the app is, how to run it with the three `--dart-define` values, test/analyze/format commands, a Layout section (compact / medium+ / large), and the shortcuts table
- [x] 6.2 Link `app/README.md` from the root README's "Pointing the Flutter app at a server" section
- [x] 6.3 Write this change's proposal, design, tasks, and `flutter-client` spec delta

## 7. Verify

- [x] 7.1 `flutter test`, `flutter analyze`, `dart format` for the app
- [x] 7.2 `make test` / `make lint` / `make fmt` at the repo root
- [x] 7.3 `openspec validate redesign-app-shell-and-layout --strict` passes (archive `redesign-search-as-overlay` and `redesign-login-reachability-and-layout` before this change, since the delta modifies requirements they introduce)

## Definition of Done

- All tasks above are checked off and every new scenario in `specs/flutter-client/spec.md` has a widget test.
- `flutter test`, `flutter analyze`, and `dart format` are clean in `app/`; `make test` and `make lint` pass at the root.
- No screen compares a width against a literal pixel constant; every banner is a `StatusStrip`; `shell.reset` is gone.
- A 1400px window shows three panes with the URL still driving which note is open; a 400px window keeps the phone chrome it had.
- `app/README.md` no longer contains the Flutter template text.
