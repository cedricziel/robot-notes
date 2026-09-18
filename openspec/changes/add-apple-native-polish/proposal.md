## Why

The client renders the same Material chrome on every platform. On an iPhone that means Android-style ink ripples, a Material spinner and pull-to-refresh, boxy alert dialogs, a vertical "more" menu, and no swipe-to-delete; on a Mac it means a menu bar left at Flutter's template defaults, with none of the app's own commands or shortcuts in it and ⌘W doing nothing. Users of Apple's platforms notice these seams first. This change makes the app follow the platform's own conventions where Flutter already offers them, and gives the Mac a real menu bar.

## What Changes

- **Theme follows the platform**: iOS and macOS drop ink ripples, iOS centers app-bar titles, and code in notes renders in Menlo (Apple has no generic `monospace` alias).
- **Adaptive controls**: confirmation and input dialogs (delete, move, new folder, disconnect) take their Cupertino form on iOS/macOS; spinners, the back glyph, and the "more" glyph follow the platform; the note's "more" menu is an iOS action sheet on iPhone/iPad and stays a popup menu on macOS.
- **Notes list on touch**: the iOS rubber-band pull-to-refresh control on Apple platforms (Material indicator elsewhere); swipe a row left to delete after the same confirmation; a status-bar tap scrolls the list to the top.
- **macOS menu bar**: the app installs its own menus (app, File, Edit, View, Note, Window) with the app's shortcuts shown natively. Items are enabled only while their command applies (Save while editing, Edit Note while viewing, New Note while the shell is up). The menu bar owns those ⌘ chords on macOS so a press reaches exactly one handler; ⌘W hides the window to the existing tray; ⌘, opens the account surface; ⌘R refreshes.
- **New in-app shortcuts everywhere**: Cmd+R / F5 refresh the list, Cmd/Ctrl+, opens the account surface.
- Android, Windows, Linux, and Web keep Material chrome; the only visible change there is swipe-to-delete on phone layouts and the two new shortcuts.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: adds requirements for platform-adaptive chrome, touch list gestures, the macOS menu bar, and the extra shortcuts; the keyboard-shortcut scenario notes that macOS routes ⌘ chords through the menu bar.

## Impact

- `app/lib/src/theme/app_theme.dart`: platform-aware builder.
- `app/lib/src/widgets/adaptive.dart` (new): dialog action, dialog text field, "more" menu, icon helpers.
- `app/lib/src/desktop/app_menu_actions.dart`, `app_menu_bar.dart` (new): handler registry and `PlatformMenuBar` tree; `tray_controller` gains `hideWindow`.
- `app/lib/main.dart`, `app_router.dart`, `notes/note_screen.dart`, `notes/notes_list_screen.dart`, `notes/folder_prompt.dart`, `search/`, `setup/`: adoption.
- No server, shared-package, or native runner changes.

## Non-goals

- A translucent/unified macOS title bar or sidebar vibrancy (needs visual verification on a Mac; separate change).
- Replacing Material with Cupertino wholesale (navigation bars, tab bars, form styling); the app keeps one widget tree and adapts at the seams.
- A native macOS Settings window; "Account…" (⌘,) reuses the existing account dialog.
- Windows/Linux menu bars.
