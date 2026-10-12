## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing accepted versus review view widget tests.
- [ ] 2.2 Add explicit proposal and history navigation to the editor.
- [ ] 2.3 Write failing type guidance and field diagnostic tests.
- [ ] 2.4 Display typed authoring assistance without replacing Markdown editing.
- [ ] 2.5 Write failing stale review and atomic group display tests.
- [ ] 2.6 Render evidence context and group review decisions.
- [ ] 2.7 Run isolated real Flutter edit and review flow.
- [ ] 2.8 Check persistence and clean up disposable app state.
- [ ] 2.9 Commit the review UI slice.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Implementation tasks are bounded to 15-minute increments; split any larger step into named substeps before applying it. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
