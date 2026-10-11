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
| Editor exposes editable-text semantics | Pass with local bridge actions | Fail |
| Legacy theme lookup inherits the adaptive host's dark theme | Pass with local theme bridge | Fail |
| Full suite | Pass after local bridge remediation | 6 pass, 3 fail |

The theme probe showed that `package:flutter/material.dart` and `package:material_ui/material_ui.dart` use different inherited themes. Super Editor reads the former. `SuperEditorThemeBridge` now projects the standalone Material and Cupertino themes into the legacy editor subtree while leaving standalone controls and `MediaQuery` inherited. Its widget tests cover dark iOS colors, typography, selection colors, theme updates, text scaling, and reduced motion.

The semantics probe focuses a mounted editor and checks for an editable-text role in the semantics tree. The same test passes with the standalone `TextField`. `AdaptiveSuperEditor` now supplies document text, focus and selection state, text replacement, selection updates, and cursor movement by character or word through semantics actions. Package widget tests verify cross-block selection and editing, undo, preserved formatting and opaque source, and read-only behavior. A label-only wrapper would not provide these actions.

Real browser verification then exposed a gap that widget semantics actions did not cover: typing into a block with web accessibility enabled did not change the document. In Flutter 3.47.6, `SemanticsTextEditingStrategy.addEventHandlers` omits the `beforeinput` listener used by the default text-editing strategy. The delta model consequently reported selection updates without the inserted text.

`AdaptiveSuperEditor` now configures web input with `enableDeltaModel: false`. Its `imeOverrides` decorator converts complete editing values into minimal insertion, deletion, replacement, or selection deltas for Super Editor's existing editing pipeline. Native platforms retain the default delta configuration, and the web keyboard brightness follows the adaptive theme. This uses public configuration hooks and does not modify the Flutter SDK or the editor package.

All 46 `adaptive_super_editor` package tests pass, including complete-value typing with formatting and undo, composition, emoji replacement, and deletion. In the rebuilt web app against a throwaway local server, direct block typing with accessibility enabled appended text to the visible paragraph, marked the draft dirty, and updated the focused accessibility input value. This verifies that browser typing path; it does not establish native screen-reader behavior.

The opaque-source tests demonstrate that each document model can retain a raw Markdown region while surrounding text changes. The production Markdown adapter has separate round-trip fixtures; these isolated opaque-source probes do not cover its complete parser or serializer.

## Limits and decision

Super Editor 0.3.0-dev.52 passes the widget compatibility gate with the local `adaptive_super_editor` bridge and is the selected editing engine. The bridge projects app themes, adds functional editable-text semantics, and adapts complete web IME values to the document editing pipeline. The app uses it for the Markdown adapter and note-screen integration.

Widget tests simulate keyboard, tap, and IME interactions and exercise semantics actions against the document editing pipeline. Browser verification additionally covers direct block typing with web accessibility enabled. Physical software keyboards, VoiceOver and TalkBack on native devices, the remaining browser accessibility interactions, and Android, iOS, Linux, and Windows runtime behavior remain unverified. No native app or production note was used. Verify those targets during platform integration.

Published upstream metadata and APIs provide additional context:

- [Super Editor package and versions](https://pub.dev/packages/super_editor/versions) describe the configurable editor and its stable and development releases. This probe pins the development release containing the editing pipeline used here.
- [Super Editor configuration](https://pub.dev/documentation/super_editor/0.3.0-dev.52/super_editor/SuperEditor-class.html) exposes component builders, styling, input policies, and selection overlays.
- [Super Editor accessibility issue](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/1072) describes related screen-reader limitations. The local test results above determine this gate.
- [Flutter Quill package](https://pub.dev/packages/flutter_quill) documents its Delta model, custom embeds, and configurable editor and toolbar. Its platform claims are not runtime validation of this app.
- [Flutter Quill accessibility work](https://github.com/singerdmx/flutter-quill/pull/2764) proposes text-field semantics for web and toolbar labels. That unpublished work was not included in this probe and does not establish native accessibility.

The adaptive host APIs used by this probe pass their current widget checks. No contribution to `material_ui` or `cupertino_ui` is needed for engine integration. App integration did reveal a local shared-helper defect: `notesPage` changed its page type across the large layout breakpoint and remounted the note controller. The motion helper now keeps each platform's page type stable and updates transition durations instead. Router regressions verify that unsaved drafts and controllers survive resizing in both directions with macOS, iOS, and Android theme overrides. Native routes retain their Material or Cupertino behavior. Reassess other shared adaptive controls only if integration tests demonstrate another reusable gap.
