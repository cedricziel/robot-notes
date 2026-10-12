## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing round-trip format and reserved metadata tests.
- [ ] 2.2 Implement knowledge metadata codecs without changing database property encodings.
- [ ] 2.3 Write failing inheritance conflict and cycle tests.
- [ ] 2.4 Resolve version-pinned type constraints.
- [ ] 2.5 Write failing external-edit restart and offline rebuild tests.
- [ ] 2.6 Persist accepted snapshots and candidate file revisions.
- [ ] 2.7 Define and test Person and Project minimum constraints.
- [ ] 2.8 Define and test Claim and Decision minimum constraints.
- [ ] 2.9 Define and test Procedure and Evidence minimum constraints.
- [ ] 2.10 Run type storage checks and commit the registry slice.

- [ ] 2.11 Write failing portable export tests for referenced type snapshots and manifests.
- [ ] 2.12 Implement portable export preserving pinned definition versions.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Implementation tasks are bounded to 15-minute increments; split any larger step into named substeps before applying it. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
