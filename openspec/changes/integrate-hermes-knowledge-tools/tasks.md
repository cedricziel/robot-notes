## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing feature-disabled memory provider regression tests.
- [ ] 2.2 Preserve existing recall and configured identity destinations.
- [ ] 2.3 Write failing capability and denied proposal tests.
- [ ] 2.4 Register type list/get and query tools.
- [ ] 2.5 Register source inspection and candidate validation tools.
- [ ] 2.6 Register proposal submit/get/amend tools.
- [ ] 2.7 Map common errors and unsupported capabilities without write fallback.
- [ ] 2.8 Write failing source opt-in and read-only configuration tests.
- [ ] 2.9 Add explicit capture configuration and event submission.
- [ ] 2.10 Write failing outbox restart and changed-event conflict tests.
- [ ] 2.11 Add durable source delivery without replacing ordinary memory writes.
- [ ] 2.12 Run real Hermes runtime contract checks and commit integration.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
