## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing round-trip format and reserved metadata tests.
- [ ] 2.2 Implement knowledge metadata codecs without changing database property encodings.
- [ ] 2.3 Write failing inheritance conflict and cycle tests.
- [ ] 2.4 Resolve version-pinned type constraints.
- [ ] 2.5 Write failing external-edit restart and offline rebuild tests.
- [ ] 2.6 Retain one accepted definition snapshot by identity and version.
- [ ] 2.7 Record an external edit as a separate candidate.
- [ ] 2.8 Restore accepted definition lookup after restart.
- [ ] 2.9 Rebuild type lookup from retained accepted snapshots.
- [ ] 2.10 Define and test Person and Project minimum constraints.
- [ ] 2.11 Define and test Claim and Decision minimum constraints.
- [ ] 2.12 Define and test Procedure and Evidence minimum constraints.
- [ ] 2.13 Run type storage checks and commit the registry slice.
- [ ] 2.14 Write failing portable export tests for referenced type snapshots and manifests.
- [ ] 2.15 Implement portable export preserving pinned definition versions.
- [ ] 2.16 Write failing type candidate propose and amendment freshness tests.
- [ ] 2.17 Bind type candidate validation to pinned definition constraints.
- [ ] 2.18 Persist type candidates using the existing review core.
- [ ] 2.19 Add authorized type acceptance with complete-group atomic publication.
- [ ] 2.20 Write failing importer activation authority and bulk group recovery tests.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
