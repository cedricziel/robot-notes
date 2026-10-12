## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing source descriptor and original-byte retention tests.
- [ ] 2.2 Add source revision blobs and vault-local references.
- [ ] 2.3 Write failing text range bounds and whole-document locator tests.
- [ ] 2.4 Implement explicit source inspection and locator validation.
- [ ] 2.5 Write failing opt-in capture and trusted scope tests.
- [ ] 2.6 Implement adapter-neutral ingestion policy checks.
- [ ] 2.7 Write failing duplicate delivery and changed-scope conflict tests.
- [ ] 2.8 Persist canonical event deduplication with source transactions.
- [ ] 2.9 Write failing purge retry and retention tests.
- [ ] 2.10 Implement unavailable references and consumed-key tombstones.
- [ ] 2.11 Run source integration checks and commit ingestion.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Implementation tasks are bounded to 15-minute increments; split any larger step into named substeps before applying it. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
