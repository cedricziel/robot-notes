## Context

See proposal.md for motivation. Today `app/macos/Runner/AppDelegate.swift` returns `true` from `applicationShouldTerminateAfterLastWindowClosed`, so closing the window ends the process and drops the realtime WebSocket. `app/lib/main.dart` is the single entrypoint (`WidgetsFlutterBinding.ensureInitialized()` → `initOtel()` → `runApp(RobotNotesApp())`); no window/tray packages exist yet (confirmed via dependency and code search).

## Goals / Non-Goals

**Goals:**

- macOS: tray icon at launch, hide-on-window-close instead of quit, tray menu with Show/Quit, single-window focus semantics.
- Keep the change additive and platform-gated so Android/iOS/Windows/Linux/Web behavior is bit-for-bit unchanged.

**Non-Goals:**

- Launch-at-login, notification badges, or a richer tray menu (unread count, quick actions) — not requested.
- Windows/Linux tray support, even though the chosen packages support it — explicitly out of scope per the proposal; the platform gate keeps this to a one-line follow-up later rather than something this change needs to validate.
- Changing App Sandbox entitlements — a status item and hide/show do not require new entitlements.

## Decisions

- **Packages: `tray_manager` + `window_manager`** (both `leanflutter`-maintained, commonly paired for exactly this "hide to tray" pattern on desktop Flutter). Alternative considered: `system_tray` — older, less actively maintained, and doesn't cover window show/hide/focus, which would still require `window_manager` anyway. Rolling a custom platform channel was rejected as unnecessary reinvention for a well-covered use case.
- **Platform gating in Dart, not build-time exclusion**: initialization code checks `Platform.isMacOS` (or the existing platform-detection helper if one exists in `app/lib`) before calling `trayManager.setIcon`/`windowManager` setup, rather than conditionally importing packages per platform. The packages are pure-Dart-facing with native shims per platform, so including them as dependencies for all platforms is safe; only the _initialization calls_ are macOS-gated. This keeps `pubspec.yaml` simple and avoids per-platform source trees.
- **Close vs. quit semantics**: only the window's close ("red button"/`Cmd+W`) action is intercepted (`windowManager.setPreventClose(true)` + a `WindowListener.onWindowClose` hook that calls `windowManager.hide()`). `Cmd+Q` / "Quit" from the Dock still quits normally via macOS's standard `applicationShouldTerminate` path, matching the convention of existing macOS menu-bar apps (e.g., closing the window keeps a background presence; Quit is explicit). The `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` flip to `false` is the backstop that keeps the process alive if the window is closed through any path `window_manager`'s listener doesn't intercept.
- **Tray click behavior**: `onTrayIconMouseDown` and the "Show robot-notes" menu item both call the same restore routine (`windowManager.show()` + `windowManager.focus()`), so there is one code path for "bring the window back," not two divergent ones.
- **Icon asset**: a new monochrome/template PNG under `app/assets/tray/` sized per macOS status-item conventions (so it renders correctly in both light and dark menu bars), loaded via `trayManager.setIcon`. Reusing the existing app icon was considered and rejected — full-color launcher icons render poorly as a 22pt status item.

## Risks / Trade-offs

- **[Risk]** A user who doesn't know Quit lives in the tray menu may think the app "won't close." → **Mitigation**: this matches widely-used macOS menu-bar app conventions (Slack, Spotify, etc.); no in-app onboarding is added for this narrow change, but the tray tooltip/menu item is explicitly labeled "Quit" rather than an icon-only control.
- **[Risk]** `tray_manager`/`window_manager` are third-party plugins; a native-side crash or missing macOS entitlement could regress app launch. → **Mitigation**: both are widely used, App Sandbox doesn't require new entitlements for `NSStatusItem`, and manual verification of a macOS debug build is a required task before merging.
- **[Risk]** Existing "quit on last window closed" behavior is relied on by nothing else in the codebase (confirmed: no other code references `applicationShouldTerminateAfterLastWindowClosed`), so no other regression surface was found.

## Migration Plan

No data migration. Rollout is a single app release; rollback is reverting the dependency addition and the two touched files (`AppDelegate.swift`, `main.dart`) plus the new asset — no server or storage changes are involved.
