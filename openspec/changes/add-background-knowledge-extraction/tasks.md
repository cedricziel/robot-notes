## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing enqueue eligibility and stable job key tests.
- [ ] 2.2 Implement durable scheduler records and explicit scope enablement.
- [ ] 2.3 Write failing lease expiry and crash checkpoint tests.
- [ ] 2.4 Claim a queued job with an expiring lease.
- [ ] 2.5 Recover an expired lease using its persisted checkpoint.
- [ ] 2.6 Schedule transient retry with bounded backoff.
- [ ] 2.7 Persist permanent failures in blocked state.
- [ ] 2.8 Write failing worker permission and source evidence tests.
- [ ] 2.9 Define extractor input and candidate output contracts.
- [ ] 2.10 Add a deterministic source-to-Claim fixture extractor.
- [ ] 2.11 Resolve fixture entity matches against accepted entries.
- [ ] 2.12 Submit candidate groups with stable job proposal keys.
- [ ] 2.13 Write failing uncertainty and contradiction diagnostics tests.
- [ ] 2.14 Preserve conservative entity matches in candidate diagnostics.
- [ ] 2.15 Write failing disable and revoke race tests.
- [ ] 2.16 Recheck eligibility before reads and proposal writes.
- [ ] 2.17 Run worker recovery checks and commit extraction.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
