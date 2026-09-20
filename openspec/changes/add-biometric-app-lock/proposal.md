## Why

The app keeps a signed-in session (and every note it has fetched) on the device, and anyone who picks up an unlocked phone or laptop can read and edit them. Users want the same guard other notes and password apps offer: ask for Face ID / Touch ID before showing the notes.

## What Changes

- The account surface gains an "App lock" switch. Turning it on or off asks the user to authenticate first, so a stranger cannot switch the lock off.
- While the lock is on, the app starts locked and locks again whenever it leaves the foreground. A full-screen lock screen replaces the content until the device owner authenticates with Face ID, Touch ID, fingerprint, or — as the platform's fallback — the device passcode. The lock screen prompts automatically and offers an "Unlock" button to retry.
- On phones the content is also covered while the app is merely inactive, so the app-switcher snapshot shows the lock screen instead of notes.
- The switch only appears where the device can authenticate the user (iOS, Android, macOS, Windows with a supported plugin backend). Web and Linux never show it.
- Disconnecting from the server also turns the lock off.
- Platform setup: `NSFaceIDUsageDescription` on iOS, `USE_BIOMETRIC` and a `FlutterFragmentActivity` host on Android.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: adds an app-lock requirement.

## Impact

- New `app/lib/src/lock/` (controller, prefs, authenticator, gate and lock screen).
- `app/lib/src/app_router.dart`: account sheet switch; `AppRouterShell` wraps a connected session in the gate.
- `app/lib/main.dart`: owns the controller; turns the lock off on disconnect.
- New app dependency: `local_auth`.
- Android `MainActivity`, manifest, and launch themes; iOS `Info.plist`.

## Non-goals

- No server involvement: the lock is a local screen guard, not encryption. Notes already cached in memory or on disk are not encrypted at rest.
- No auto-lock timeout or "lock after N minutes"; leaving the foreground locks immediately.
- No in-app passcode of our own — the device's own passcode is the fallback.
- Not applied to the setup screen: nothing is stored before a server is configured.
