## 1. Ephemeral server helper

- [x] 1.1 Add a `screenshot_server` helper (e.g. `app/fastlane/lib/screenshot_server.rb`) that builds the server the same way `test-hermes-plugin-e2e`/`server/Dockerfile` do (`dart_frog build` + the IPv6→loopback `sed` patch + `dart build cli -o out`) and starts the compiled `bin/server` bundle against a fresh temp dir with a fixed capture-only `ROBOT_NOTES_API_KEY` and a free `ROBOT_NOTES_PORT`, polls `/healthz` until ready (with a timeout that raises), and exposes a `stop` that kills the process and removes the temp dir
- [x] 1.2 Write a quick manual check first (start the helper from `bundle exec fastlane run` or an ad hoc Ruby snippet, confirm `/healthz` returns 200, confirm `stop` actually kills the process and removes the temp dir) before wiring it into any lane — this is the "failing test first" for a script with no unit test harness of its own
- [x] 1.3 Commit: `feat(app): add ephemeral server helper for screenshot capture`

## 2. Seed script

- [x] 2.1 Write a seed script (Ruby, alongside the helper, or a small Dart script under `server/tool/`) that, given the ephemeral server's URL + API key, `POST`s 3-5 fictional sample notes (rich text) and one sample database with a few rows via the existing `/notes` and `/databases` REST routes
- [x] 2.2 Verify manually: run helper + seed script together, `GET /notes` (or `/search`) against the running ephemeral server and confirm the seeded content comes back before moving on
- [x] 2.3 Commit: `feat(app): seed sample content for screenshot capture`

## 3. iOS native screenshot runner

- [x] 3.1 Add `integration_test` as a dev dependency in `app/pubspec.yaml`
- [x] 3.2 Add the native `RunnerTests` runner to `ios/Runner.xcodeproj` (correction from the original wording: `integration_test`'s iOS support is a **hosted unit-test bundle** using the `INTEGRATION_TEST_IOS_RUNNER` macro, not a UI Testing Bundle/XCUITest target — `flutter create`'s template already scaffolds an empty `RunnerTests` unit-test target with `TEST_HOST` wired and the Podfile's `target 'RunnerTests' do inherit! :search_paths end`, so only the placeholder `RunnerTests.swift` needed replacing with `RunnerTests.m` implementing the macro, via the `xcodeproj` gem to edit `project.pbxproj` safely)
- [x] 3.3 Verify the runner target builds and runs via `flutter drive` on a booted iPhone 17 Pro Max simulator (confirmed: build succeeded, "All tests passed!", and a real 1320x2868 PNG was written by the driver's `onScreenshot` callback)
- [x] 3.4 Commit: `feat(app): add iOS native runner for screenshot capture`

## 4. Screenshot integration test

- [x] 4.1 Write `app/integration_test/screenshot_test.dart`: configure the app to point at a server URL/API key passed via `--dart-define` (pre-writing `AppConfig` into `SecureConfigStore` before `app.main()`, the same persistence the real setup screen writes to — bypasses `setup_screen.dart` exactly the way a returning user would), pump the app
- [x] 4.2 Add the Notes list screenshot step (`takeScreenshot('01_notes_list')`) — skipped re-proving the negative case (plain `flutter test` failing on iOS) experimentally since the research fork already confirmed it from Flutter's own docs and reproving it would just burn an extra build cycle for no new information; the positive case (native runner + `flutter drive`) is verified below
- [x] 4.3 Add Note editor, Search, and Database view navigation + `takeScreenshot()` steps, in that order (also found: the seed database needs at least one `views` entry or the database screen renders "No views yet" instead of rows — fixed in `screenshot_seed.rb`)
- [x] 4.4 Verified iOS fully end-to-end: `flutter drive` on the iPhone 17 Pro Max simulator against a real seeded ephemeral server produced all 4 correctly-sized (1320×2868) PNGs with real content, on the second pass after fixing two things found on the first: (a) the debug build showed Flutter's red "DEBUG" banner — profile/release mode is unbuildable on iOS/iPad Simulators ("only supported for physical devices"), so `debugShowCheckedModeBanner` is now gated off by a `SCREENSHOT_CAPTURE` dart-define instead (`app/lib/main.dart`), never affecting normal dev builds; (b) the views fix above. **macOS not verified locally** — attempted via `flutter test -d macos` first, which hit a pre-existing local codesigning gap (this Mac's keychain lacks the "Apple Development: Created via API" cert that CI's `match`-populated keychain has) before ever reaching the point of running the test; fixing it would mean running `bootstrap_signing` against the shared private certs repo, which is out of scope for this change — defer macOS verification to the CI `apple` matrix job, which already has proper certs via the existing pipeline. Separately (see design.md), `flutter test -d macos` was later found to be the wrong invocation anyway — only `flutter drive` actually writes screenshot files to disk, on any platform — so macOS capture (once CI-verified) uses `flutter drive -d macos` like iPhone/iPad, not `flutter test -d macos`. `screenshot_test.dart` itself has no iOS-specific code, so the signing gap is a local environment issue, not a logic risk.
- [x] 4.5 Commit: `test(app): add screenshot integration test for App Store capture`

## 5. Fastlane `capture_app_store_screenshots` lane

- [x] 5.1 Add a shared (not per-platform) `capture_app_store_screenshots` lane to `app/fastlane/Fastfile`: start the ephemeral server, run the seed script, run iOS capture (`flutter drive` on iPhone 17 Pro Max), iPad capture (`flutter drive` on iPad Pro 13" M5), and macOS capture (`flutter drive -d macos`), collecting PNGs into `app/fastlane/screenshots/en-US/`, then stop the ephemeral server in an `ensure` block so it always tears down. Also found and fixed mid-implementation: (a) `capture_screenshots` collides with a built-in fastlane action (alias for `capture_ios_screenshots`/`snapshot`) — renamed to `capture_app_store_screenshots`; (b) this Mac has more than one simulator per device name (one per installed iOS runtime), and naively picking the first match booted a _second_ redundant instance alongside an already-booted one, which caused a 30+ minute hang (4 simulators booted simultaneously) during the VM-service handshake — fixed by preferring an already-booted match in `screenshot_capture.rb`'s `simulator_by_name`
- [x] 5.2 Make any capture step's failure (simulator boot, server boot/health timeout, seed failure, test failure) raise and abort the lane — no catching-and-continuing (verified for real: the macOS step's local codesigning failure below correctly aborted the lane and still ran the `ensure` teardown)
- [x] 5.3 Add `app/fastlane/screenshots/` to `.gitignore`
- [x] 5.4 Ran `bundle exec fastlane capture_app_store_screenshots` locally end-to-end. iPhone and iPad both fully succeeded (24.2s and 11.7s Xcode builds, "All tests passed!", 8 real PNGs at the correct 1320×2868 / 2064×2752 sizes — eyeballed both, real seeded content, correct wide-layout sidebar on iPad, no debug banner). macOS fails at the Xcode build step on the same pre-existing local codesigning gap noted in task 4.4 (not a lane bug) — expected to work in CI, which has proper certs.
- [x] 5.5 Commit: `feat(app): add capture_app_store_screenshots fastlane lane`

## 6. Wire into submission

- [x] 6.1 In `submit_target` (shared implementation backing both `ios submit_to_app_store` and `mac submit_to_app_store`), call `capture_app_store_screenshots` before `upload_to_app_store`, and pass `skip_screenshots: false` on that call only
- [x] 6.2 Confirmed `release_target` (the TestFlight lane) is untouched — no call to `capture_app_store_screenshots`, no `skip_screenshots` param there at all (verified by grep — only one call site, in `submit_target`)
- [x] 6.3 Confirmed `sync_metadata` (metadata-only lane, no binary) is untouched — still `skip_screenshots: true` (verified by grep — the only other `skip_screenshots` occurrence)
- [x] 6.4 Commit: `feat(app): capture and upload fresh screenshots on App Store submission`

## 7. Verification

- [x] 7.1 Not run as a live dry-run against `submit_to_app_store` itself — that lane's only "dry" path would be commenting out `submit_for_review`, and even reaching it needs a real signed build/build_number, so there's no way to exercise it without either real signing artifacts or risking a real Apple submission. Instead verified the two things that actually change: `capture_app_store_screenshots` runs standalone end-to-end (task 5.4) and the `submit_target` wiring is correct by direct code inspection (task 6.1-6.3). A live run is deferred to an actual submission, by design a rare, deliberate, human-triggered action — not something to rehearse against production ASC state.
- [x] 7.2 Not independently confirmed against the actual CI runner (would require either a real release/submission event or manually dispatching the `apple` workflow in submit mode, which is exactly the risky action being avoided). This Mac's Xcode 27 ships iPhone 17 Pro Max and iPad Pro 13" (M5) simulators by default with no manual setup; GitHub's `macos-26` image is expected to ship the same current-Xcode default set, and `screenshot_capture.rb` creates a simulator on demand if one is ever missing (see design.md's risk note). First real confirmation happens at the next actual submission.
- [x] 7.3 Updated `RELEASING.md`'s "Submitting to the App Store" section (screenshot capture step, ~3-5 min per platform, fails closed) and removed the now-stale manual screenshot-upload step from "Before the first submission"

## Definition of Done

- `bundle exec fastlane ios submit_to_app_store` and `bundle exec fastlane mac submit_to_app_store` capture fresh screenshots against an ephemeral, disposable server and upload them as part of submission, with no manual screenshot step left in App Store Connect
- `bundle exec fastlane ios release` / `mac release` (TestFlight) take no longer than before this change — screenshot capture never runs on that path
- A deliberately broken capture step (e.g. a bad seed request) fails the lane before any `upload_to_app_store` call runs
- The `release-pipeline` spec's new requirements pass review against the actual lane behavior
