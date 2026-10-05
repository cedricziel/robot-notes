## Implementation (each task is a small independent increment)

- [x] Add neutral light/dark theme and rectangular component styles.
- [x] Refine inset note/sidebar rows while preserving existing actions.
- [x] Add compact workspace destinations and a database library.
- [x] Keep compose, folder browsing and uploads reachable from compact chrome.
- [x] Add persisted appearance and sidebar-width preferences.
- [x] Add Settings entry points and retain account/security actions.
- [x] Refine reader title/metadata and scrolling grouped properties.
- [x] Add search keyboard selection and retained-query restoration.
- [x] Add keyboard/semantic sidebar resize and reduced-motion handling.
- [x] Add regression coverage for destination state, persistence, keyboard
      interaction, and responsive reader/property layouts.
- [x] Render and visually review actual light/dark Mac and iPhone widgets.
- [x] Run client analysis and the complete client suite.
- [x] Compile the web release build.
- [x] Compile the native Mac app without relying on local signing profiles.

## Definition of Done

- Existing edit locks, autosave, reconciliation, gestures, menu and route tests
  pass alongside new navigation/layout regressions.
- Client analysis reports no errors/warnings; formatting and diff checks pass.
- Light/dark and compact/roomy layouts are reviewed from actual widget renders.
- Build results and native validation limitations are recorded honestly.

## Validation

Final combined redesign/migration verification: 814 client tests passed; web/Wasm, unsigned macOS, and iOS simulator builds passed. Live throwaway-server verification confirmed app edit/save/reload/search and phone/tablet/desktop resizing. See [docs/verification](../../../docs/verification/README.md).

App analysis has no errors/warnings; existing constructor-style informational lints remain with the newer SDK. Formatting and diff checks pass. Signed distribution and native Android/Linux/Windows runtime checks remain release validation.
