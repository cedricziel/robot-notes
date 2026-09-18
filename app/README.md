# robot-notes app

The Flutter client for [robot-notes](../README.md): a multi-platform
(Android, iOS, macOS, Windows, Linux, Web) front end that lists, reads,
edits, locks, and searches notes against the server's HTTP API and streams
presence, lock, and change events over its WebSocket. It is one package in
the repo's Dart pub workspace; run `make install` at the repo root once
before working here.

## Running against a server

The app reads its base URL, API key, and actor identity at startup. Pass them
in via `--dart-define` (handy for both `flutter run` and `flutter build`):

```sh
flutter run \
  --dart-define=ROBOT_NOTES_BASE_URL=http://127.0.0.1:8080 \
  --dart-define=ROBOT_NOTES_API_KEY=rn_your_secret \
  --dart-define=ROBOT_NOTES_ACTOR=cedric
```

For desktop/release builds bake those values into the bundle the same way:

```sh
flutter build macos \
  --dart-define=ROBOT_NOTES_BASE_URL=https://notes.example.com \
  --dart-define=ROBOT_NOTES_API_KEY=rn_your_secret \
  --dart-define=ROBOT_NOTES_ACTOR=cedric
```

Without the defines the app starts on its setup screen, where the same three
values can be entered by hand (or, when the server offers it, replaced by an
OIDC sign-in). See the root README for how to start the server itself.

## Tests, analysis, formatting

Run from this directory:

```sh
flutter test              # widget and unit tests under test/
flutter analyze           # must report no issues
dart format .             # CI enforces formatting
```

`make test-app`, `make lint`, and `make fmt` at the repo root run the same
things as part of the workspace-wide targets.

## Layout

Every width-dependent decision goes through `lib/src/layout/breakpoints.dart`,
which maps the window width to a Material 3 window size class:

| Size class | Width  | What you get                                                                                                                                                                                                                      |
| ---------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| compact    | < 600  | Phone chrome: bottom navigation (Search / Folders / Account), a floating action menu, the folder tree in a drawer, search as a top sheet, editor preview off by default.                                                          |
| medium+    | ≥ 600  | Wide chrome (medium ≥ 600, expanded ≥ 840): toolbar actions (New note, Upload file, Search, Refresh, Account) instead of the FAB, an inline resizable folder sidebar, search as a centered palette, editor preview on by default. Notes still open as full-screen pages. |
| large      | ≥ 1200 | Three-pane shell: resizable folder sidebar, notes list, and the open note side by side. `/` shows a "Select a note" placeholder in the note pane; the list highlights the open note.                                              |

A pane inside the shell classifies by its own width, not the window's, so the
notes list column keeps its list layout even in a very wide window. Pane
widths (sidebar range, list pane, reading column, editor split) live in
`PaneSizes` in the same file.

## Keyboard shortcuts

Cmd on macOS, Ctrl elsewhere.

| Shortcut                           | Action                                                       |
| ---------------------------------- | ------------------------------------------------------------ |
| Cmd/Ctrl + N                       | New note in the currently selected folder                    |
| Cmd/Ctrl + K, Cmd/Ctrl + Shift + F | Open search                                                  |
| Cmd + R, F5                        | Refresh the notes list                                       |
| Cmd/Ctrl + ,                       | Open the account surface                                     |
| Cmd/Ctrl + E                       | Enter edit mode on the open note (also: double-tap the body) |
| Cmd/Ctrl + S                       | Save the note being edited                                   |
| Esc                                | Close the note, the search overlay, or the account sheet     |
| Cmd + W (macOS)                    | Hide the window to the menu-bar tray                         |

Edit mode is explicit because entering it acquires the server-side editor
lock; an always-editable note would hold a lock for every open note and block
other humans and agents.

On the macOS desktop build the Cmd chords above live in the native menu bar
(File, View, Note, Window) rather than in the in-app shortcut maps, so each
press reaches exactly one handler and the menu shows the shortcut the way a
Mac user expects. See "Platform behaviour" below.

## Platform behaviour

One widget tree, adapted at the seams. Every decision keys off the theme's
platform (`Theme.of(context).platform`), so a widget test can pin it with
`AppTheme.light(platform: …)`.

| Where            | iOS / macOS                                                                                                                                                              | Everywhere else                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------- |
| Theme            | No ink ripples; centered app-bar titles on iOS; `Menlo` for code in notes                                                                                                | Material ripples, leading-aligned titles          |
| Dialogs          | Cupertino alerts (delete, move, new folder, disconnect), Cupertino text field for input                                                                                  | Material alerts                                   |
| Note "…" menu    | iOS: action sheet with Cancel and a destructive Delete. macOS: popup menu                                                                                                | Popup menu                                        |
| Glyphs           | Chevron back, horizontal-dots "more", platform spinners                                                                                                                  | Arrow back, vertical dots                         |
| Notes list       | iOS overscroll pull-to-refresh; status-bar tap scrolls to top                                                                                                            | Material refresh indicator                        |
| Phone layouts    | Swipe a row left to delete (after the usual confirmation) — on every platform                                                                                            | Same                                              |
| macOS menu bar   | App, File, Edit, View, Note, Window menus; items enable only while their command applies (Save while editing, Edit Note while viewing…); Cmd+W hides to the tray | No platform menu (Flutter supports macOS only) |

The menu bar is driven by `lib/src/desktop/app_menu_actions.dart`: the shell
and the front note register their handlers there, and
`lib/src/desktop/app_menu_bar.dart` turns the registry into a
`PlatformMenuBar`. A screen that wants a menu item registers a handler;
`null` renders the item disabled.

## Where things live

- `lib/src/app_router.dart` — routes, the three-pane shell, search and account overlays, app-level shortcuts.
- `lib/src/notes/` — notes list, folder tree sidebar, note view/editor and their controllers.
- `lib/src/search/`, `lib/src/setup/` — search overlay content and the first-run flow.
- `lib/src/widgets/` — shared `StatusStrip`, `ErrorStrip`, `EmptyState`, `ResizablePanel`, `ConnectionBanner`, and the platform-adaptive helpers in `adaptive.dart`.
- `lib/src/desktop/` — macOS tray controller, menu-bar registry, and the `PlatformMenuBar` tree.
- `lib/src/theme/app_theme.dart` — the one platform-aware `ThemeData` builder and the shared Markdown stylesheet.
- `lib/src/format/note_time.dart` — timestamp and relative-time formatting.

Behaviour is specified in `openspec/specs/flutter-client/spec.md` at the repo
root; new work goes through an OpenSpec change under `openspec/changes/`.
