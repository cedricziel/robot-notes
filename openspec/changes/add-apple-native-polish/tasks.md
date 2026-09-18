## 1. Platform-aware theme

- [x] 1.1 Write failing tests in `app/test/src/theme/app_theme_test.dart`: `isApplePlatform`, `NoSplash` on iOS/macOS only, centered app-bar title on iOS only, `Menlo` code font on Apple, theme defaults to the ambient platform
- [x] 1.2 Make `AppTheme.light/dark` take a `platform`, set `ThemeData.platform`, `splashFactory`, `centerTitle`; add `AppTheme.codeFont` and use it in the Markdown stylesheet
- [x] 1.3 `flutter analyze`, `dart format`; commit `feat(app): platform-aware theme for iOS and macOS`

## 2. Adaptive dialogs, menus, and glyphs

- [x] 2.1 Write failing tests in `app/test/src/widgets/adaptive_test.dart`: `useCupertino`, `adaptiveDialogAction` (Cupertino vs Filled/Text buttons), `AdaptiveDialogTextField`, `AdaptiveMoreMenu` (glyph, iOS action sheet, Material popup)
- [x] 2.2 Add `app/lib/src/widgets/adaptive.dart`
- [x] 2.3 Write failing Apple-platform tests for the note screen (`note_screen_apple_test.dart`): chevron back glyph, action sheet with destructive Delete, Cupertino move dialog, popup menu on macOS
- [x] 2.4 Convert the delete/move/new-folder/disconnect dialogs to `AlertDialog.adaptive` with adaptive actions and text field; switch spinners to `.adaptive`; derive the back/more glyphs from the theme
- [x] 2.5 Update `folder_prompt_test.dart` to read the pre-filled value through `EditableText` (the input is no longer a `TextFormField` on every platform)
- [x] 2.6 `flutter analyze`, `dart format`; commit `feat(app): adaptive dialogs, action sheet, and glyphs on Apple platforms`

## 3. Notes list on touch

- [x] 3.1 Write failing tests in `notes_list_screen_apple_test.dart`: Cupertino refresh control on iOS/macOS (Material elsewhere) that re-fetches on pull; the `add-touch-gestures` swipe-to-delete behaves the same under an Apple theme (Cupertino confirmation); the list has no private scroll controller
- [x] 3.2 Rebuild the list body on `CustomScrollView` + `SliverList.separated` behind `_RefreshableScrollView`; paginate via `NotificationListener`; add haptic feedback to the swipe
- [x] 3.3 `flutter analyze`, `dart format`; commit `feat(app): iOS pull-to-refresh, swipe-to-delete, primary scroll for the notes list`
- [x] 3.4 Merge `main` (`add-touch-gestures` landed its own swipe-to-delete): keep main's `Dismissible`, drop the narrow-only variant, make the note view's new pull-to-refresh adaptive

## 4. macOS menu bar

- [x] 4.1 Write failing tests in `app/test/src/desktop/app_menu_actions_test.dart` for the owner-keyed registry and `AppMenuActionsScope.maybeOf`
- [x] 4.2 Add `app/lib/src/desktop/app_menu_actions.dart`
- [x] 4.3 Write failing tests in `app_menu_bar_test.dart`: top-level menus, disabled-until-registered items, shortcuts on items, Close Window only with a handler, provided items, Edit menu forwards intents to the focused field, `menuOwnsShortcut`, `withoutMenuOwnedShortcuts` (macOS only), `AppMenuBar` sends `Menu.setMenus` on macOS and re-sends on change, nothing off macOS
- [x] 4.4 Add `app/lib/src/desktop/app_menu_bar.dart`; add `hideWindow` to both tray controllers (with tests)
- [x] 4.5 Write failing tests: the shell registers its handlers (`app_router_test.dart`), drops menu-owned chords on macOS, Cmd+R refreshes, Ctrl+, opens the account surface; the note screen registers Edit/Save/Close/Move/Delete by state and hands the menu back after a pushed note pops (`note_screen_menu_actions_test.dart`)
- [x] 4.6 Wire `AppMenuBar` + `AppMenuActionsScope` in `main.dart`; register handlers in `_AppShellState` and `_NoteScreenState`; add `RefreshNotesIntent`/`OpenAccountIntent`; filter in-app bindings with `withoutMenuOwnedShortcuts`
- [x] 4.7 `flutter analyze`, `dart format`; commit `feat(app): native macOS menu bar with live-enabled items and shortcuts`

## 5. Docs, spec, verification

- [x] 5.1 Update `app/README.md`: shortcuts table (⌘R/F5, ⌘,/Ctrl+,, ⌘W) and a "Platform behaviour" section
- [x] 5.2 `npx -y @fission-ai/openspec@1.13.0 validate add-apple-native-polish --strict`
- [x] 5.3 Full `flutter test`, `dart analyze`, `dart format --set-exit-if-changed .` green
- [ ] 5.4 Manual run-through on a Mac (`flutter run -d macos`): menu bar shows the six menus; File › New Note is greyed on the setup screen and enabled in the shell; ⌘N creates exactly one note; Save greys out when not editing and ⌘S saves while editing; ⌘W hides to the tray and the tray restores; Edit › Select All works in the editor
- [ ] 5.5 Manual run-through on an iPhone simulator: pull-to-refresh is the iOS control on the list and the note; swipe a row to delete; the note's "…" opens an action sheet; delete/move dialogs are Cupertino; no ink ripples

## Definition of Done

- All checkboxes above are checked, except 5.4/5.5 which need Apple hardware and are tracked for the next Mac session.
- `flutter test` passes with the new Apple-platform and menu-bar tests; `dart analyze` and `dart format` are clean.
- `openspec validate add-apple-native-polish --strict` passes.
- Android/Windows/Linux/Web behaviour is covered by the existing suite (which still runs on the Material path) and only gains the two new shortcuts.
