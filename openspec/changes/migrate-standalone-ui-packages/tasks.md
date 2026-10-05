# Tasks

- [x] Inspect official package APIs and dependency interop.
- [x] Migrate dependencies, minimum SDK, and source/test imports.
- [x] Preserve Markdown styling and add cross-platform light/dark interop regression tests.
- [x] Update workspace requirements and document bridge removal.
- [x] Verify client suite, analysis, web compilation, and available native build.
- [x] Verify Docker web-builder toolchain pin.

## Definition of Done

The migrated client compiles and tests pass, all six targets remain supported, legacy dependency themes match the app, and build-toolchain limitations are recorded accurately.

## Validation

Final verification: 814 client tests passed, web release and Wasm dry run passed, unsigned macOS and iOS simulator builds passed. Full Docker web-builder build passed with the fresh pinned Flutter 3.47.2 checkout. Analyzer has no errors/warnings; existing constructor-style infos remain.

The real Flutter web app connected to a throwaway local server, saved an edit confirmed by the API at version 3, reloaded it, found it through search, and retained readable layouts across phone/tablet orientations and desktop sizes. Details and screenshots: [docs/verification](../../../docs/verification/README.md). Native Android/Windows/Linux and real-device orientation checks remain unverified.
