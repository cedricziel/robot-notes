## 1. Ephemeral server helper

- [x] 1.1 Add a `screenshot_server` helper (e.g. `app/fastlane/lib/screenshot_server.rb`) that builds the server the same way `test-hermes-plugin-e2e`/`server/Dockerfile` do (`dart_frog build` + the IPv6→loopback `sed` patch + `dart build cli -o out`) and starts the compiled `bin/server` bundle against a fresh temp dir with a fixed capture-only `ROBOT_NOTES_API_KEY` and a free `ROBOT_NOTES_PORT`, polls `/healthz` until ready (with a timeout that raises), and exposes a `stop` that kills the process and removes the temp dir
- [x] 1.2 Write a quick manual check first (start the helper from `bundle exec fastlane run` or an ad hoc Ruby snippet, confirm `/healthz` returns 200, confirm `stop` actually kills the process and removes the temp dir) before wiring it into any lane — this is the "failing test first" for a script with no unit test harness of its own
- [ ] 1.3 Commit: `feat(app): add ephemeral server helper for screenshot capture`

## 2. Seed script

- [ ] 2.1 Write a seed script (Ruby, alongside the helper, or a small Dart script under `server/tool/`) that, given the ephemeral server's URL + API key, `POST`s 3-5 fictional sample notes (rich text) and one sample database with a few rows via the existing `/notes` and `/databases` REST routes
- [ ] 2.2 Verify manually: run helper + seed script together, `GET /notes` (or `/search`) against the running ephemeral server and confirm the seeded content comes back before moving on
- [ ] 2.3 Commit: `feat(app): seed sample content for screenshot capture`

## 3. iOS native screenshot runner

- [ ] 3.1 Add `integration_test` as a dev dependency in `app/pubspec.yaml`
- [ ] 3.2 Add the minimal `ios/RunnerUITests` XCUITest target to `ios/Runner.xcodeproj` (the standard `integration_test` iOS boilerplate: a test case that just launches the app so `flutter drive` can attach)
- [ ] 3.3 Verify the empty runner target builds and runs via `flutter drive` on a booted iPhone 17 Pro Max simulator against the default app (no screenshot logic yet) before writing the real test
- [ ] 3.4 Commit: `feat(app): add iOS XCUITest runner for screenshot capture`

## 4. Screenshot integration test

- [ ] 4.1 Write `app/integration_test/screenshot_test.dart`: configure the app to point at a server URL/API key passed via `--dart-define` (bypassing `setup_screen.dart`), pump the app
- [ ] 4.2 Add the Notes list screenshot step (`takeScreenshot('01_notes_list')`) and verify it runs (expect it to fail/no-op on iOS via plain `flutter test`, confirming the native runner from step 3 is actually required — the negative case is the "failing test first" here)
- [ ] 4.3 Add Note editor, Search, and Database view navigation + `takeScreenshot()` steps, in that order
- [ ] 4.4 Verify all 4 screenshots are produced running via `flutter drive` (iOS) and `flutter test -d macos` (macOS) against a locally-running ephemeral server + seed data
- [ ] 4.5 Commit: `test(app): add screenshot integration test for App Store capture`

## 5. Fastlane `capture_screenshots` lane

- [ ] 5.1 Add a shared (not per-platform) `capture_screenshots` lane to `app/fastlane/Fastfile`: start the ephemeral server, run the seed script, run iOS capture (`flutter drive` on iPhone 17 Pro Max), iPad capture (`flutter drive` on iPad Pro 13" M5), and macOS capture (`flutter test -d macos`), collecting PNGs into `app/fastlane/screenshots/en-US/` with ASC's expected filenames, then stop the ephemeral server in an `ensure` block so it always tears down
- [ ] 5.2 Make any capture step's failure (simulator boot, server boot/health timeout, seed failure, test failure) raise and abort the lane — no catching-and-continuing
- [ ] 5.3 Add `app/fastlane/screenshots/` to `.gitignore`
- [ ] 5.4 Run `bundle exec fastlane capture_screenshots` locally end-to-end and manually eyeball the 3 produced screenshot sets
- [ ] 5.5 Commit: `feat(app): add capture_screenshots fastlane lane`

## 6. Wire into submission

- [ ] 6.1 In `submit_target` (shared implementation backing both `ios submit_to_app_store` and `mac submit_to_app_store`), call `capture_screenshots` before `upload_to_app_store`, and pass `skip_screenshots: false` on that call only
- [ ] 6.2 Confirm `release_target` (the TestFlight lane) is untouched — no call to `capture_screenshots`, `skip_screenshots` stays as-is there
- [ ] 6.3 Confirm `sync_metadata` (metadata-only lane, no binary) is untouched — still `skip_screenshots: true`
- [ ] 6.4 Commit: `feat(app): capture and upload fresh screenshots on App Store submission`

## 7. Verification

- [ ] 7.1 Dry-run the full `submit_to_app_store` lane locally against a real (already-uploaded) TestFlight build in "no-op" mode if fastlane/deliver supports a dry-run flag, or at minimum run everything up through screenshot capture and stop before the actual submit call, to confirm the wiring works end-to-end
- [ ] 7.2 Confirm CI (`macos-26` runner, the `apple` matrix job) has the simulators this lane needs (iPhone 17 Pro Max, iPad Pro 13" M5) available by default, or document/add whatever `xcrun simctl` setup is needed
- [ ] 7.3 Update `RELEASING.md`'s App Store section to mention that submission now captures screenshots automatically and roughly how long that adds

## Definition of Done

- `bundle exec fastlane ios submit_to_app_store` and `bundle exec fastlane mac submit_to_app_store` capture fresh screenshots against an ephemeral, disposable server and upload them as part of submission, with no manual screenshot step left in App Store Connect
- `bundle exec fastlane ios release` / `mac release` (TestFlight) take no longer than before this change — screenshot capture never runs on that path
- A deliberately broken capture step (e.g. a bad seed request) fails the lane before any `upload_to_app_store` call runs
- The `release-pipeline` spec's new requirements pass review against the actual lane behavior
