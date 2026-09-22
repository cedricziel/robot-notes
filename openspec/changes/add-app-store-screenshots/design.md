## Context

`app/fastlane/Fastfile` already has `ios`/`mac` `build`, `release`, and `submit_to_app_store` lanes (see `openspec/changes/add-app-store-publishing`), plus a `sync_metadata` lane that today passes `skip_screenshots: true`, `skip_binary_upload: true` to `upload_to_app_store`. The server (`server/`) is a Dart Frog app with `POST /notes` and `POST /databases` REST routes, a single static bearer key read from `ROBOT_NOTES_API_KEY`, and reads `ROBOT_NOTES_DATA_DIR`/`ROBOT_NOTES_PORT` at startup — it needs no Docker to run. It does, however, need a real build: the `test-hermes-plugin-e2e` Makefile target (`Makefile:90-154`) documents that `dart_frog dev` (and a bare `dart run main.dart`) skip Dart's build hooks, which `package:sqlite3` (3.x) needs to bundle a native `libsqlite3` — that resolves by luck on most developer machines but fails outright on a bare CI runner. The proven fix already in this repo is `dart_frog build` + `dart build cli` (same production-parity compile `server/Dockerfile` uses), which produces a self-contained `bin/server` bundle. The screenshot ephemeral-server helper reuses that same build-and-run recipe rather than a bare `dart run`. The Flutter app (`app/`) has no `integration_test` dependency or `integration_test/` directory today; it asks for a server URL + API key on first launch (`app/lib/src/setup/setup_screen.dart`). App Store Connect currently has zero screenshots for "Robot Notes", which blocks submitting for review.

## Goals / Non-Goals

**Goals:**

- Produce real, representative App Store Connect screenshots (iPhone, iPad, Mac) with no manual screen-grabbing
- Never expose or touch the maintainer's real notes/data while doing so
- Keep the routine TestFlight release path exactly as fast as it is today

**Non-Goals:**

- Screenshot localization beyond `en-US`
- A general-purpose Flutter screenshot-testing framework for other purposes (visual regression, etc.) — this is App Store Connect capture only
- Solving the Apple reviewer demo-server problem (separate, explicitly out of scope per proposal.md)

## Decisions

**Run the server directly, not via Docker — but build it, don't `dart run` it raw.** GitHub-hosted `macos-26` runners (used by the `apple` CI matrix job) don't reliably support Linux containers the way Ubuntu runners do. The server already reads its config from plain env vars (`ROBOT_NOTES_DATA_DIR`, `ROBOT_NOTES_PORT`, `ROBOT_NOTES_API_KEY`), so no container runtime is needed. But it must be started the same way `test-hermes-plugin-e2e` and `server/Dockerfile` do — `dart_frog build` then `dart build cli` — not via `dart_frog dev` or a bare `dart run main.dart`, both of which skip the Dart build hooks `package:sqlite3` needs to bundle a native `libsqlite3`; that fails on a bare CI runner even though it happens to work on most developer machines.

**Own the capture script instead of adopting `mmcc007/screenshots`.** That's the closest thing to a community standard for Flutter App Store screenshots, but it has 56+ open issues and no recent confirmed release — real risk of breaking against current Flutter/Xcode with no upstream fix available. A ~100-line fastlane lane plus one integration test file, built directly on tools already in the repo (fastlane, `flutter test`/`flutter drive`), is small enough to own and debug ourselves.

**Native XCUITest runner for iOS, plain `flutter test` for macOS.** Confirmed via Flutter's own `integration_test` docs: `IntegrationTestWidgetsFlutterBinding.takeScreenshot()` only writes files on iOS when the test runs through a native Xcode UI-test target (`flutter drive` driving an `XCUITest` runner), not through `flutter test` directly. macOS doesn't have this restriction — `flutter test integration_test/screenshot_test.dart -d macos` captures directly. So iOS gets one new minimal `ios/RunnerUITests` target (boilerplate: launches the Flutter app and lets the Dart-side test drive it); macOS needs no native changes.

**One device per required App Store Connect size class.** 2026 ASC accepts one screenshot set per device family at its largest size, auto-scaled to older listing pages: iPhone 17 Pro Max (6.9"), iPad Pro 13" (M5), and the Mac build itself. No multi-size matrix needed, which keeps the lane to exactly 3 capture runs.

**Screenshot content and order come from a fixed seed + fixed navigation script**, not randomized or pulled from real usage: a few short, clearly-fictional notes (e.g. a reading list, a meeting-notes example), one sample database (e.g. a small reading tracker), captured in the order Notes list → Note editor → Search → Database view. This keeps output deterministic and reviewable — reruns should look the same modulo cosmetic UI changes.

**Trigger only from `submit_to_app_store`, not `release`.** Release history shows TestFlight releases (`release` lane) firing many times a day; `submit_to_app_store` fires rarely (a handful of times ever). Booting 3 simulators/targets plus an ephemeral server on every TestFlight push would add real CI time and flakiness surface for a listing asset that only matters at submission time.

**Fail closed on any capture error.** No fallback to previously-captured or previously-published screenshots — a broken capture step fails the lane before `upload_to_app_store` runs, so a bad or missing screenshot never ships silently.

## Risks / Trade-offs

- **[Risk] Simulator/Xcode drift between this Mac and the CI runner** could make capture pass locally but fail (or look different) in CI → Mitigation: dry-run locally first (already verified this Mac has Xcode 27 with the iPhone 17 Pro Max and iPad Pro 13" (M5) simulators available), then verify once against the actual `macos-26` CI image before relying on it for a real submission.
- **[Risk] The one-time `submit_to_app_store` run becomes slower and has more failure surface** (3 simulators + a server + an integration test, all before the actual upload) → Mitigation: this is acceptable because submission is already a deliberate, infrequent, human-triggered action (`workflow_dispatch` or promoting a pre-release), not something on the hot path.
- **[Risk] Flutter/Xcode version bumps could break the native `RunnerUITests` target or `takeScreenshot()` behavior** → Mitigation: it's a small, self-owned target (not a third-party plugin), so it can be fixed in place; failures are loud (lane fails) rather than silent.
- **[Trade-off] Sample data needs to be maintained by hand** (seed script content) as the app's UI evolves, rather than being generated from real usage → accepted, since realistic-but-fictional data is also what avoids leaking anything real into a public App Store listing.

## Open Questions

- Exact wording/content of the seeded sample notes and database (cosmetic, doesn't affect specs/approach/tasks — decide while implementing and adjust freely after eyeballing the captured PNGs).
