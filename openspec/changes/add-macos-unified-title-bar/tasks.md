## 1. Window-chrome controller and drag/zoom functions

- [x] 1.1 Write failing tests in `app/test/src/desktop/window_chrome_test.dart`: `WindowChromeController.init()` on macOS calls `ensureInitialized()` then `setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true)` once; off macOS makes no calls; `startWindowDrag` calls `startDragging()`; `toggleWindowZoom` calls `maximize()` when not maximized and `unmaximize()` when it is
- [x] 1.2 Add `app/lib/src/desktop/window_chrome.dart` (conditional export), `window_chrome_io.dart` (`WindowChromeController`, `startWindowDrag`, `toggleWindowZoom`), `window_chrome_stub.dart` (no-ops)
- [x] 1.3 `flutter analyze`, `dart format`; commit `feat(app): macOS window chrome controller and MacWindowChrome inset`

## 2. MacWindowChrome widget and app wiring

- [x] 2.1 Write failing tests in `app/test/src/desktop/mac_window_chrome_test.dart`: on macOS the child's `MediaQuery.padding.top` is raised to `kMacTitleBarInset` (28) or kept if already larger; a full-width, `kMacTitleBarInset`-tall drag strip (`Key('window.dragStrip')`) sits at the top; a pan on it invokes `onDragStart`, a double-tap invokes `onDoubleTap`; off macOS (android/iOS/windows/linux) the child and its padding are unchanged and no strip exists
- [x] 2.2 Add `app/lib/src/desktop/mac_window_chrome.dart` (`MacWindowChrome`, `kMacTitleBarInset`)
- [x] 2.3 Wire `WindowChromeController().init()` next to the tray controller in `main.dart`, and mount `MacWindowChrome` between `AppMenuActionsScope` and `AppRouterShell`
- [x] 2.4 `flutter analyze`, `dart format`; commit (same commit as 1.3 unless split)

## 3. Three-pane sidebar honours the inset

- [x] 3.1 Write a failing test in `app/test/src/app_router_test.dart` (three-pane shell group): under an ambient `MediaQuery` top padding of 28, `shell.sidebar`'s `Material` still starts at y=0 but the "Folders" header (and the notes list pane's `notes.title` app-bar text) sit at or below y=28
- [x] 3.2 Wrap the sidebar's `FolderTreeSidebar` in `SafeArea(bottom: false, ...)` inside the `shell.sidebar` `Material` in `app_router.dart`'s `_buildThreePane`
- [x] 3.3 Confirm (no code change expected) that `NotesListScreen`'s inline sidebar on medium/expanded layouts needs no inset change, since its Scaffold's `AppBar` already consumes `MediaQuery.padding.top`
- [x] 3.4 `flutter analyze`, `dart format`; commit `feat(app): three-pane sidebar honours the macOS title-bar inset`

## 4. Docs, spec, verification

- [x] 4.1 Update `app/README.md`: add a macOS window row to "Platform behaviour"; mention `lib/src/desktop/` now also holds the window chrome
- [x] 4.2 Update `openspec/changes/add-apple-native-polish/proposal.md`'s Non-goals to point at this change
- [x] 4.3 `npx -y @fission-ai/openspec@1.13.0 validate add-macos-unified-title-bar --strict`
- [x] 4.4 Full `flutter test`, `dart analyze`, `dart format --set-exit-if-changed .` green; commit `docs(app): OpenSpec change and README for the macOS unified title bar`
- [ ] 4.5 Manual run-through on a Mac (`flutter run -d macos`): title bar is transparent with no title text; traffic lights are visible and usable; dragging the top strip moves the window; double-clicking it zooms/unzooms; the sidebar's tint extends up under the traffic lights and "Folders" sits below them; no content is clipped or overlapped anywhere else (setup screen, note view, search overlay)

## Definition of Done

- All checkboxes above are checked, except 4.5 which needs Apple hardware and is tracked for the next Mac session.
- `flutter test` passes with the new window-chrome and `MacWindowChrome` tests, plus the updated three-pane shell test; `dart analyze` and `dart format` are clean.
- `openspec validate add-macos-unified-title-bar --strict` passes.
- Every other platform is unaffected: `WindowChromeController` and `MacWindowChrome` are no-ops off macOS, covered by the same tests that cover the macOS path.
