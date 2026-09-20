## 1. App lock

- [x] 1.1 Write failing tests for `AppLockController` (load, enable/disable behind a prompt, lock/unlock, prompt in flight, unsupported device, disable)
- [x] 1.2 Implement `AppLockController`, `AppLockPrefs`, and `BiometricAuthenticator` (`local_auth`) so 1.1 passes
- [x] 1.3 Write failing widget tests for `AppLockGate` (hidden until loaded, cold-start prompt, retry, background lock, content stays mounted, method names)
- [x] 1.4 Implement `AppLockGate`, `AppLockScreen`, and `AppLockScope` so 1.3 passes
- [x] 1.5 Write failing widget tests for the account "App lock" switch (on after a prompt; absent when unsupported), then add it and make the account sheet scrollable
- [x] 1.6 Wire the controller in `main.dart` and `AppRouterShell`; drop the lock on disconnect
- [x] 1.7 Platform setup: `NSFaceIDUsageDescription`, `USE_BIOMETRIC`, `FlutterFragmentActivity`, AppCompat launch themes
- [ ] 1.8 Verify on a real iPhone (Face ID), a Mac (Touch ID), and an Android device (fingerprint): enable, background/resume, cancel then retry, disconnect

## Definition of Done

- `flutter analyze` and `flutter test` pass in `app/`
- Task 1.8 done by hand; the platform prompts cannot be exercised in unit tests
