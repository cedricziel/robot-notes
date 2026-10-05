# Local runtime verification — 2026-10-05

Ran a throwaway Dart Frog development server bound to 127.0.0.1 with isolated temporary data and a disposable API key. It served the actual release-built Flutter web app, not mocked widgets.

Connected through normal setup, opened a seeded note, acquired its edit lock, edited and saved through the app. A direct server API read confirmed the saved content and version 3; reloading the app restored it. Compact Search found the saved text through the real search API. Settings showed Connection Connected; changing Appearance to Dark updated the app and persisted through reload.

Checked the same live note at 390×844 and 844×390 (phone portrait/landscape), 768×1024 and 1024×768 (tablet portrait/landscape), and 1440×900 (desktop). Short landscape content remained reachable by scrolling. No browser warning/error entries were captured. These are browser viewport checks, not native device orientation tests.

## Evidence

- [Connected desktop workspace](live-desktop.jpg)
- [Phone portrait](live-phone-portrait.jpg)
- [Phone landscape](live-phone-landscape.jpg)
- [Tablet portrait](live-tablet-portrait.jpg)
- [Tablet landscape](live-tablet-landscape.jpg)
- [Connected dark Settings](live-dark-settings.jpg)

## Supporting validation

- Final client suite: 814 tests passed.
- Final web release build and Wasm compilation dry run passed.
- Final unsigned macOS Release build passed.
- Final iOS simulator build passed; simulator launch succeeded. Native UI interactions were not verified.
- Full Docker web-builder build passed with Flutter 3.47.2/Dart 3.13.2 and the pinned framework commit. No image published.
- App analysis has no errors/warnings; 27 existing constructor-style informational suggestions remain. Changed Dart formatting and git diff checks passed.
- Project-local verification skill passed its validator. Its helper was started, /healthz checked, then stopped; temporary data cleanup was confirmed, including startup failure cleanup.

Android SDK is absent locally. Native Linux/Windows require their host toolchains; the existing Linux container has no compiler/GTK desktop dependencies. Signed native distribution and real-device orientation testing remain release checks. Existing flutter_otel_native SwiftPM/privacy-manifest build warnings are unchanged.

The maintained workflow is [.agents/skills/verify-project-local/SKILL.md](../../.agents/skills/verify-project-local/SKILL.md). Temporary credentials, server data, and runtime logs are excluded from Git.

Cleanup completed: browser credentials cleared via Disconnect, viewport override reset, verification tabs closed, dev processes stopped, temporary data removed, and the simulator started for this run shut down.

## CodeRabbit follow-up

All three findings were reproduced and fixed: compact Search now observes list updates; keyboard selection follows note identity and discards obsolete result keys; preference writes catch initialization/write failures and log rejected writes. The 90 affected router/search/preferences tests passed, and the updated web release build and Wasm dry run succeeded. Targeted search/preferences analysis reported no issues.

A fresh throwaway instance served the updated real app. An app edit was saved and confirmed through the server API at version 2. With compact Search mounted and the original recent note selected, a second note was created on the server: it appeared immediately without changing destinations, the original note remained highlighted, and Enter opened the original note. No browser errors/warnings were captured.

[Live updated Search evidence](live-review-search.jpg). The disposable credentials were cleared through Disconnect; browser sizing was reset and the verification tab and server were stopped.
