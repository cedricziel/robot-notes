## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing candidate set and unset validation tests.
- [ ] 2.2 Implement complete candidate group validation.
- [ ] 2.3 Write failing local reference and optional relation group tests.
- [ ] 2.4 Resolve candidate-local identities and Evidence references.
- [ ] 2.5 Write failing proposal key reuse and amendment revision tests.
- [ ] 2.6 Persist idempotent responses with proposal history.
- [ ] 2.7 Write failing concurrent acceptance and deletion tests.
- [ ] 2.8 Serialize checks across affected identities.
- [ ] 2.9 Inject failure during multi-entry publication and test recovery.
- [ ] 2.10 Implement recoverable all-or-none group publication.
- [ ] 2.11 Run atomic proposal checks and commit the mutation slice.

- [ ] 2.12 Write failing type upgrade preview and coherent migration tests.
- [ ] 2.13 Implement explicit reviewed migration without changing existing pinned versions.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Implementation tasks are bounded to 15-minute increments; split any larger step into named substeps before applying it. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
