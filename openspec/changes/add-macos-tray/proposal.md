## Why

On macOS, closing the app's window today quits the whole process (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `true`), which drops the WebSocket connection used for realtime note sync and presence. Users who want robot-notes to keep receiving `changed`/presence events in the background have to keep the window open and visible. A menu-bar (tray) presence lets the app keep running and reachable without an open window, matching the behavior of other always-on menu-bar utilities on macOS.

## What Changes

- Add `tray_manager` and `window_manager` package dependencies to `app/pubspec.yaml`.
- On macOS only, register a status bar (tray) icon at startup with a menu: "Show robot-notes" and "Quit".
- On macOS only, closing the main window hides it instead of quitting the app (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`); the process keeps running with the tray icon visible.
- Clicking the tray icon or its "Show robot-notes" item restores and focuses the existing window (never spawns a second window).
- The tray menu's "Quit" item terminates the app for real.
- Android, iOS, Windows, Linux, and Web keep today's behavior (quit/backgrounding is unchanged) — this change is scoped to macOS.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: adds requirements for macOS tray presence and window-close behavior (hide-to-tray instead of quit, tray menu actions, single-window focus).

## Impact

- `app/pubspec.yaml`: new dependencies (`tray_manager`, `window_manager`).
- `app/lib/main.dart`: initialize `window_manager` and register the tray icon/menu on macOS at startup.
- `app/macos/Runner/AppDelegate.swift`: `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
- New tray asset (menu-bar icon, likely a template/monochrome PNG) under `app/assets/`.
- No server, shared-package, or non-macOS platform code changes.
