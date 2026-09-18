## Why

`add-apple-native-polish` flagged a translucent/unified macOS title bar as a follow-up needing visual verification on real hardware. Today the Mac build runs with the system's normal opaque title bar: a plain strip above the app's own chrome, wasting vertical space and looking unlike the native Mac apps (Notes, Mail, Finder) the client is trying to resemble. This change makes the title bar transparent and folds it into the app's own content, the way those apps do.

## What Changes

- At startup, on macOS only, the window switches to `window_manager`'s hidden title-bar style with the traffic-light buttons kept visible: the title bar becomes part of the window's content area instead of a separate opaque strip, and no title text is shown.
- The Flutter content tree gets a top inset (28px) wherever it currently reads `MediaQuery.padding.top`, so nothing the app draws sits under the traffic lights — the same mechanism that already insets content below a phone's status bar.
- A new `MacWindowChrome` widget applies that inset app-wide and draws a transparent strip across the top of the window: dragging it moves the window (there is no title bar left to drag by), and double-clicking it zooms/unzooms, mirroring what a native title bar does.
- The three-pane shell's folder sidebar keeps its background painted all the way to the top (so the traffic lights sit over the sidebar's own color, not a gap) while its "Folders" header and controls inset below the strip.
- Every other platform is unaffected: `MacWindowChrome` and the window-chrome controller are no-ops off macOS.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: adds a requirement that the macOS window uses a unified (transparent) title bar with an inset content area and a draggable/zoomable top strip.

## Impact

- `app/lib/src/desktop/window_chrome.dart`, `window_chrome_io.dart`, `window_chrome_stub.dart` (new): sets the native title-bar style at startup; exposes drag/zoom functions for the strip.
- `app/lib/src/desktop/mac_window_chrome.dart` (new): the inset + drag-strip widget.
- `app/lib/main.dart`: wires the controller and mounts `MacWindowChrome`.
- `app/lib/src/app_router.dart`: the three-pane shell's sidebar `Material` gains a `SafeArea` around its content so the header insets while the background still paints under the title bar.
- No server, shared-package, or native runner (`MainFlutterWindow.swift`, entitlements, `Info.plist`) changes — `window_manager` sets the style at runtime.

## Non-goals

- Sidebar vibrancy (a translucent, blurred sidebar background) — a separate visual-effects change.
- A custom title/toolbar area with app-drawn window controls or a search field in the strip — the strip is drag/zoom-only for now.
- Windows/Linux window chrome — this targets macOS only, matching the rest of the desktop-polish work.
- Persisting or restoring window size/position — unrelated to the title-bar style.
