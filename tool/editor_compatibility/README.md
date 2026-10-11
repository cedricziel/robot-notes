# Editor compatibility probes

These independent Flutter packages evaluate the editor gate for `add-block-note-editor`. They import the app's real `AdaptiveMoreMenu` and platform-selection helper. They do not participate in the Dart workspace or change the app's dependencies.

## Run the checks

From `tool/editor_compatibility/super_editor`, run:

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
```

Repeat these commands from `tool/editor_compatibility/flutter_quill`. Analyze the shared helper from `tool/editor_compatibility/common` after running `flutter pub get` there.

To run only the currently passing baseline checks, use:

```sh
flutter test --no-pub --exclude-tags compatibility_gate --reporter expanded
```

The full suites intentionally fail while a candidate does not meet the adoption requirements. Do not use the baseline-only command as evidence that the gate passed. Keep these probes separate from the production test suite until an engine is adopted.

## Results on October 11, 2026

Tests ran on a macOS host with Flutter 3.47.6 and Dart 3.13.5. The app's CI pins Flutter 3.47.2, so exact CI-toolchain compatibility remains unverified. Both candidates resolve alongside `material_ui` 1.6.0 and `cupertino_ui` 1.1.2. Lockfiles record the transitive dependency versions.

| Check | Super Editor 0.3.0-dev.52 | Flutter Quill 11.6.0 |
| --- | --- | --- |
| Compile and dependency resolution | Pass | Pass |
| Cross-block deletion and undo | Pass, with restored node identities | Pass |
| Opaque source survives an adjacent edit, undo, and redo | Pass, custom document node | Pass, custom embed |
| Hardware arrow moves the caret | Pass | Pass |
| Shared block actions open and dismiss by tap | Pass | Pass |
| Shared platform link dialog opens and dismisses above editor | Pass | Pass |
| Composed input survives a host rebuild | Pass, delta IME interface | Pass before removal |
| Remove editor during active composition | Not separately evaluated | Fails with a callback into a defunct element |
| Standard text-field semantics positive control | Pass | Pass |
| Editor exposes editable-text semantics | Fail | Fail |
| Legacy theme lookup inherits the adaptive host's dark theme | Fail | Fail |
| Full suite | 7 pass, 2 fail | 6 pass, 3 fail |

The theme probe shows that `package:flutter/material.dart` and `package:material_ui/material_ui.dart` use different inherited themes. Both published editors read the former. An iOS dark theme supplied through the app's standalone `MaterialApp` appears as a light fallback to the legacy lookup. This is an integration gap, not a compile failure. An explicit theme bridge or an editor migration must be tested before adoption.

The semantics probe focuses a mounted editor and checks for an editable-text role in the semantics tree. The same test passes with the standalone `TextField`. Neither candidate supplies the role in the tested editor configuration. Adding a label alone would not provide accessible text or selection editing.

The opaque-source tests demonstrate that each document model can retain a raw Markdown region while surrounding text changes. They do not implement Markdown parsing, custom block rendering, or a complete lossless serializer. Those remain later tasks.

## Limits and decision

No engine passes the gate. Super Editor is the provisional candidate for remediation because its node identities and custom block model fit the planned Markdown adapter and its simulated composition check passes. It is not selected as an app dependency.

Widget tests simulate keyboard, tap, and IME interactions. They do not prove physical software-keyboard behavior, native screen-reader operation, browser accessibility, or Android, iOS, Linux, and Windows runtime behavior. No native app or production note was used.

Published upstream metadata and APIs provide additional context:

- [Super Editor package and versions](https://pub.dev/packages/super_editor/versions) describe the configurable editor and its stable and development releases. This probe pins the development release containing the editing pipeline used here.
- [Super Editor configuration](https://pub.dev/documentation/super_editor/0.3.0-dev.52/super_editor/SuperEditor-class.html) exposes component builders, styling, input policies, and selection overlays.
- [Super Editor accessibility issue](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/1072) describes related screen-reader limitations. The local test results above determine this gate.
- [Flutter Quill package](https://pub.dev/packages/flutter_quill) documents its Delta model, custom embeds, and configurable editor and toolbar. Its platform claims are not runtime validation of this app.
- [Flutter Quill accessibility work](https://github.com/singerdmx/flutter-quill/pull/2764) proposes text-field semantics for web and toolbar labels. That unpublished work was not included in this probe and does not establish native accessibility.

Before app integration, remediate editable-text semantics and theme integration, rerun the full suites, then verify the relevant real platform interactions. A fix to either engine requires its own regression coverage. The existing source editor remains the application's editor while this gate is unresolved.
