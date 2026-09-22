## Why

App Store Connect has no screenshots for "Robot Notes" yet, which blocks submitting the app for App Store review — `add-app-store-publishing` deliberately left screenshots as a manual, by-hand step, and nobody has done it. There's no capture automation in the repo at all today.

## What Changes

- **NEW** ephemeral-server helper that runs the Dart server directly (`ROBOT_NOTES_DATA_DIR`/`ROBOT_NOTES_PORT`/`ROBOT_NOTES_API_KEY` against a temp dir, no Docker) and waits on `/healthz`, for use only during screenshot capture
- **NEW** seed script that posts a handful of fictional sample notes and one sample database to the ephemeral server via its existing REST routes
- **NEW** Flutter integration test (`app/integration_test/screenshot_test.dart`) that points the app at the ephemeral server and walks Notes list → Note editor → Search → Database view, capturing a screenshot at each screen
- **NEW** one-time native XCUITest runner target (`ios/RunnerUITests`) so iOS screenshot capture can run via `flutter drive` (plain `flutter test` cannot capture screenshots on iOS); macOS capture runs via plain `flutter test -d macos`
- **NEW** shared fastlane lane `capture_screenshots` that drives iPhone 17 Pro Max, iPad Pro 13", and macOS captures and collects PNGs into `app/fastlane/screenshots/en-US/`
- **MODIFIED** `submit_to_app_store` (both `ios` and `mac` lanes) calls `capture_screenshots` before uploading, with `skip_screenshots: false` only on that submission upload — the routine `release` (TestFlight) lane is untouched, since screenshots only matter for the App Store listing and TestFlight releases ship many times a day

## Capabilities

### Modified Capabilities

- `release-pipeline`: App Store submission (`submit_to_app_store`) now regenerates and uploads screenshots as part of submitting a build for review, superseding the "done once by hand" approach `add-app-store-publishing` assumed

## Non-goals

- Automated screenshots on every TestFlight `release` — only `submit_to_app_store` triggers capture
- The Apple reviewer demo server/credentials in `app/fastlane/metadata/review_information/notes.txt` — still placeholders, handled separately, out of scope here
- Localizing screenshots beyond `en-US`
- Android, Windows, Linux, or web screenshots
- Adopting the community `mmcc007/screenshots` gem (unmaintained; building directly on fastlane + `integration_test` instead)
- Multi-size screenshot matrices for older device classes — 2026 App Store Connect only requires one size per device family (iPhone 6.9", iPad 13", Mac ≥1280×800), auto-scaled for older listing pages

## Impact

- `app/fastlane/Fastfile`: new `capture_screenshots` lane; `submit_to_app_store` lanes gain a call to it and flip `skip_screenshots`
- `app/integration_test/screenshot_test.dart`: new
- `app/ios/RunnerUITests` (new Xcode UI test target) and `app/ios/Runner.xcodeproj`: modified to add it
- `app/fastlane/screenshots/en-US/`: new, generated output (gitignored)
- A small seed/ephemeral-server helper script under `app/fastlane/` or `server/tool/`
- No new repository secrets; no changes to the `release` (TestFlight) lane or the `apple` CI matrix job's trigger conditions
