## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing proposal persistence and amendment tests.
- [ ] 2.2 Add durable proposal records using existing revision identities.
- [ ] 2.3 Write failing stale and orphaned comment anchor tests.
- [ ] 2.4 Persist revisioned comments and review state.
- [ ] 2.5 Write failing disjoint acceptance and overlapping save tests.
- [ ] 2.6 Implement block freshness checks under mutation locks.
- [ ] 2.7 Inject interruption before publication and verify recovery.
- [ ] 2.8 Run proposal integration checks and commit the review core.
- [ ] 2.9 Write failing default-human and conservative automatic acceptance eligibility tests.
- [ ] 2.10 Implement separate review authority and recorded automatic eligibility checks.
- [ ] 2.11 Write failing direct human save history and overlapping re-review tests.
- [ ] 2.12 Preserve retained denial history and explicit authorized purge semantics.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
