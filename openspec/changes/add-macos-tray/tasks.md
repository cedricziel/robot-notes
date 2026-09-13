## 1. Dependencies and asset

- [x] 1.1 Add `tray_manager` and `window_manager` to `app/pubspec.yaml` dependencies and run `flutter pub get` from `app/`; verify it resolves with no version conflicts.
- [x] 1.2 Add a template (monochrome) tray icon PNG at `app/assets/tray/tray_icon.png` (plus `@2x`/`@3x` if needed) and register the `assets/tray/` directory in `app/pubspec.yaml`'s `flutter: assets:` list; verify `flutter pub get` still succeeds and the asset shows up in the build's asset manifest.

## 2. Tray controller (testable core logic)

- [x] 2.1 Write a failing test in `app/test/src/desktop/tray_controller_test.dart` asserting that, given a fake `isMacOS: true`, calling `TrayController.init()` sets the tray icon, tray menu (Show/Quit items), and calls `setPreventClose(true)` on an injected window-manager fake.
- [x] 2.2 Write a failing test asserting that on `isMacOS: false`, `TrayController.init()` makes no calls to the injected tray/window fakes (platform gate no-ops cleanly).
- [x] 2.3 Write a failing test asserting the window-close callback calls `hide()` (not app termination) on the injected window-manager fake.
- [x] 2.4 Write a failing test asserting both the tray icon's mouse-down handler and the "Show robot-notes" menu item invoke the same restore routine (`show()` then `focus()`) on the injected window-manager fake.
- [x] 2.5 Write a failing test asserting the "Quit" menu item invokes the injected app-exit callback.
- [x] 2.6 Implement `app/lib/src/desktop/tray_controller.dart` (`TrayController` class with constructor-injected window-manager/tray-manager wrappers and an app-exit callback) so tests 2.1-2.5 pass. (Split into a conditional-export shim plus `tray_controller_io.dart`/`tray_controller_stub.dart` so `dart:io`-dependent packages never reach the Web build.)

## 3. Wire into app startup and native shell

- [x] 3.1 Call `TrayController(...).init()` from `app/lib/main.dart` after `initOtel()` and before `runApp(...)`, using the real `window_manager`/`tray_manager` singletons and `Platform.isMacOS`; verify `flutter analyze` passes with no new warnings. (Fire-and-forget via `unawaited(...)` so it doesn't delay first paint.)
- [x] 3.2 In `app/macos/Runner/AppDelegate.swift`, change `applicationShouldTerminateAfterLastWindowClosed` to return `false`; verify the file still compiles via `flutter build macos --debug`.

## 4. Manual verification on macOS

- [ ] 4.1 Run `flutter run -d macos` from `app/`; verify a menu-bar icon appears at launch.
- [ ] 4.2 Close the main window (red button); verify the window hides, the process keeps running (check `flutter run`'s attached console is still live), and the tray icon remains.
- [ ] 4.3 Click the tray icon and separately the "Show robot-notes" menu item; verify each restores and focuses the same window with no second window created.
- [ ] 4.4 Select "Quit" from the tray menu; verify the process exits and the tray icon disappears.
- [ ] 4.5 Verify `Cmd+Q` while the window is focused still quits the app normally (unchanged convention).

**Blocked in this environment**: `flutter build macos --debug` gets through dependency resolution, plugin registration (tray_manager/window_manager both appear correctly in the generated Swift package and Podfile), and CocoaPods install, then fails at code signing (`No profiles for 'com.cedricziel.robotnotes.app' were found`) — this sandbox has no Apple Developer signing identity/provisioning profile installed. That's an environment/credentials limitation unrelated to this change; section 4 needs a run on a machine with the project's signing set up.

## 5. Spec and repo hygiene

- [x] 5.1 Run `npx -y @fission-ai/openspec@1.13.0 validate add-macos-tray --strict` and fix any reported issues.
- [x] 5.2 Run the app's lint/format (`dart_pre_commit` / `flutter analyze` / `dart format`) and `/simplify` over the new/changed files.
- [ ] 5.3 Commit with atomic, conventional-commit messages (e.g. `feat(app): add macOS tray controller`, `feat(app): hide to tray on window close`), one commit per logical step above. (Not committed yet — awaiting explicit go-ahead.)

## Definition of Done

- All checkboxes above are checked.
- `app/test/src/desktop/tray_controller_test.dart` passes and covers: macOS init wiring, non-macOS no-op, hide-on-close, show/focus on tray click and menu item, quit on menu item.
- `flutter analyze` and the project's formatter/lint pass with no new warnings.
- Manual macOS run-through (section 4) completed and confirmed working.
- `openspec validate add-macos-tray --strict` passes.
- Other platforms' behavior is verified unchanged (no tray code executes off macOS).
