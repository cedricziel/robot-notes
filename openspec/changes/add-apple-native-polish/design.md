## Context

See proposal.md. Every screen uses Material widgets with no platform branching beyond `VisualDensity.adaptivePlatformDensity` and the typography Flutter already picks per platform. Keyboard chords are bound twice (meta and control) in an app-level `Shortcuts` map and in the note screen's `CallbackShortcuts`. macOS runs with the Flutter template's `MainMenu.xib` (app menu, Edit, View, Window, Help) which knows nothing about the app; ⌘W has no binding at all.

## Goals / Non-Goals

**Goals**

- Cupertino idioms where they matter most on iOS: dialogs, action sheet, pull-to-refresh, no ripples, chevron/horizontal-dots glyphs, status-bar scroll-to-top.
- A macOS menu bar that mirrors the app's commands and their enabled state, with the app's shortcuts shown on the items and ⌘W/⌘,/⌘R wired.
- Everything gated on `Theme.of(context).platform` (widgets) or `defaultTargetPlatform` (menu bar), so tests can pin a platform and other platforms are untouched.

**Non-goals**: see proposal.md.

## Decisions

- **`Theme.platform` as the switch for adaptive widgets, not `defaultTargetPlatform`.** Flutter's own `.adaptive` constructors read the theme, and it is what a widget test can set (`AppTheme.light(platform: …)`). `Icons.adaptive` reads `defaultTargetPlatform` instead, so the app derives its two adaptive glyphs from the theme itself (`adaptiveBackIcon`, `adaptiveMoreIcon`) to stay consistent.
- **`AlertDialog.adaptive` + a small `adaptiveDialogAction` helper** rather than hand-built Cupertino dialogs: keys on the actions stay identical, so every existing test drives both variants. `AdaptiveDialogTextField` wraps the one input-in-a-dialog case (folder path) the same way.
- **Action sheet on iOS only.** macOS keeps the popup menu: a sheet sliding up from the bottom of a desktop window is a phone idiom.
- **Notes list on `CustomScrollView` for every platform**, with `CupertinoSliverRefreshControl` prepended on Apple platforms and `RefreshIndicator` wrapping the Material variant. One item builder, no duplicated list code. The private `ScrollController` is replaced by a `NotificationListener` for pagination so the list is the Scaffold's primary scrollable, which is what iOS's status-bar tap needs.
- **Swipe-to-delete stays as `add-touch-gestures` shipped it** (every layout, the row springs back after the confirmation resolves); this change only adds haptic feedback to the swipe and the Cupertino dialog behind it.
- **Menu bar as a pure function of a handler registry.** `AppMenuActions` (a `ChangeNotifier`) holds the shell's and the front note's handlers; `buildAppMenus(actions)` produces the `PlatformMenuBar` tree with `onSelected: null` for anything unregistered, which macOS renders disabled. Screens register in `didChangeDependencies` and withdraw in `dispose`. Registration is keyed by an owner token because Flutter disposes a replaced screen *after* its replacement mounted; without the token the old note would wipe the new note's handlers. A note covered by another route (push) withdraws its handlers and re-registers on pop, using `ModalRoute.isCurrent` as the trigger.
- **The menu bar owns its ⌘ chords on macOS.** The macOS embedder gives the framework the first look at a key equivalent and only then re-dispatches it to the main menu, so leaving the in-app bindings in place would work — but if that order ever differed, ⌘N would create two notes. Removing the menu-owned chords from the in-app maps on macOS (`withoutMenuOwnedShortcuts`) makes exactly one handler fire regardless. Ctrl chords, Escape, and ⇧⌘F (not on any menu item) stay in-app. The Edit menu (Undo/Cut/Copy/Paste/Select All) is *not* in that set: text fields handle those first and the menu only receives an unhandled press, which it forwards as a text-editing `Intent` to whatever has focus.
- **⌘W hides the window** through the tray controller (`hideWindow`) rather than closing it, matching what the red button already does on macOS.
- **No native runner changes.** `PlatformMenuBar` replaces `MainMenu.xib`'s menu at runtime; the xib stays as the fallback until Flutter sets the menu.

## Risks / Trade-offs

- **[Risk]** `PlatformMenuBar` replaces the whole menu bar, so anything not listed disappears (e.g. the template's Help menu, "Paste and Match Style"). → Mitigation: the app never had content behind those; the standard provided items (About, Services, Hide, Quit, Full Screen, Minimize, Zoom) are all included.
- **[Risk]** Cupertino dialogs with a text field look different from the Material ones the tests were written against. → Mitigation: the existing tests keep running on the Material path; dedicated Apple-platform tests cover the Cupertino path for every converted dialog.
- **[Risk]** Neither an iOS nor a macOS run is possible in the environment this was built in. → Mitigation: every platform branch has a widget test pinning the platform, and the menu-bar test asserts the exact serialized menu sent over the `flutter/menu` channel; the manual run-through is listed as an open task.

## Migration Plan

No data or API changes. Rollback is reverting the app commits; no server or storage involvement.
