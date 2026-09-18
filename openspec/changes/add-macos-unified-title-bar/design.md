## Context

See proposal.md. The macOS build already uses `window_manager` (for the tray controller's `hide`/`show`/`focus`/`setPreventClose`) and `TitleBarStyle` is part of that same package, so no new dependency is needed. `main.dart` already runs one desktop-only setup step (`TrayController().init()`) before `runApp`; the window-chrome controller follows the identical shape. The app already has one place, `MediaQuery.padding.top`, that every phone-safe-area decision reads (`ConnectionBanner`, every `AppBar`), so reusing it for the title-bar inset means no new plumbing — widgets that already cooperate with a phone's status bar cooperate with the Mac's title bar for free.

## Goals / Non-Goals

**Goals**

- The native window itself, not just Flutter's drawing, has no title bar text and no separate opaque strip; traffic lights stay put and usable.
- Flutter content never renders under the traffic lights, on every screen and pane, without hunting down every screen that needs the extra inset.
- The window is still fully draggable and zoomable, since removing the title bar removes the OS's own drag/zoom handling for that area.

**Non-goals**: see proposal.md.

## Decisions

- **`TitleBarStyle.hidden` with `windowButtonVisibility: true`**, not `setAsFrameless` (which also removes the traffic lights) or a fully custom-drawn title bar. This is exactly what `window_manager`'s own docs describe as the "hidden inset" style macOS apps use for a unified look, and it needs no native code changes — `MainFlutterWindow.swift` stays untouched, matching how the tray controller's `setPreventClose` already works purely through the Dart-side channel.
- **A single shared inset constant (`kMacTitleBarInset = 28`)** rather than reading `windowManager.getTitleBarHeight()` at runtime. The height is fixed by macOS's own traffic-light layout and doesn't change at runtime; a constant keeps `MacWindowChrome` synchronous and keeps its widget test deterministic (an async call would force the initial build to render with no inset for a frame).
- **Raise `MediaQuery.padding.top` to (at least) the inset, never replace it.** A window that somehow already reports a larger top padding (e.g. a future notch-style Mac) keeps that value; `MacWindowChrome` only raises a padding that's smaller than the inset, mirroring how `SafeArea` composes rather than overrides.
- **The drag strip is hand-built with `GestureDetector` + `startWindowDrag()`, not `window_manager`'s `DragToMoveArea` widget.** `DragToMoveArea` pulls in `dart:io`-only code at the widget level; keeping `MacWindowChrome` itself free of `dart:io` (with the actual platform calls behind the same conditional-export pattern as `tray_controller.dart`) means the widget compiles and is unit-testable on every platform, including Web, without a stub subclass.
- **`onDragStart`/`onDoubleTap` are constructor-overridable**, defaulting to the real `startWindowDrag`/`toggleWindowZoom` functions. Tests inject no-op-recording callbacks instead of hitting a real platform channel, the same reason `TrayController` takes an injectable `WindowManager`.
- **The three-pane sidebar's `Material` keeps painting from y=0; only a `SafeArea` around its content (the "Folders" header and tree) moves down.** Insetting the whole `Material` would leave a gap of the *shell's* background color above the sidebar instead of the sidebar's own color under the traffic lights — the visual a unified title bar is supposed to produce is the sidebar's tint extending up, not a seam.
- **No change to `SessionHost`'s `ConnectionBanner`/top-padding-removal dance or to `NotesListScreen`'s AppBar.** Both already consume `MediaQuery.padding.top` (a `SafeArea` and `AppBar`'s own `primary: true` behavior, respectively), so raising that value is enough; widget tests in this change assert that rather than re-deriving it.

## Risks / Trade-offs

- **[Risk]** A fixed 28px inset could be wrong if a future macOS or `window_manager` release changes the traffic-light row's height. → Mitigation: the constant lives in one place (`kMacTitleBarInset`) and the widget test pins the exact value, so a real mismatch shows up as a visible gap or overlap on the next Mac run-through, not a silent drift.
- **[Risk]** Neither a Mac build nor a real window-drag/zoom interaction can be exercised in this environment. → Mitigation: `WindowChromeController` and the drag/zoom functions are unit-tested against a mocked `WindowManager` (mirroring `tray_controller_test.dart`), and `MacWindowChrome`'s gesture wiring is tested via its overridable callbacks; the manual Mac run-through is a tracked, unchecked task.
- **[Risk]** Wrapping the sidebar's content in an extra `SafeArea` could double-inset if a caller later nests another `SafeArea` there. → Mitigation: `SafeArea` composes (it only ever consumes padding, never adds it twice for the same edge on the same axis at the same level), and the new widget test asserts the resulting inset is exactly the applied value.

## Migration Plan

No data, API, or native-project changes. Rollback is reverting the app commits; nothing to migrate or undo elsewhere.
