## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing enqueue eligibility and stable job key tests.
- [x] 2.2 Implement durable scheduler records and explicit scope enablement.
- [ ] 2.3 Write failing lease expiry and crash checkpoint tests.
- [x] 2.4 Claim a queued job with an expiring lease.
- [x] 2.5 Recover an expired lease using its persisted checkpoint.
- [x] 2.6 Schedule transient retry with bounded backoff.
- [x] 2.7 Persist permanent failures in blocked state.
- [ ] 2.8 Write failing worker permission and source evidence tests.
- [x] 2.9 Define extractor input and candidate output contracts.
- [x] 2.10 Add a deterministic source-to-Claim fixture extractor.
- [ ] 2.11 Resolve fixture entity matches against accepted entries.
- [x] 2.12 Submit candidate groups with stable job proposal keys.
- [ ] 2.13 Write failing uncertainty and contradiction diagnostics tests.
- [ ] 2.14 Preserve conservative entity matches in candidate diagnostics.
- [ ] 2.15 Write failing disable and revoke race tests.
- [x] 2.16 Recheck eligibility before reads and proposal writes.
- [ ] 2.17 Run worker recovery checks and commit extraction.
- [ ] 2.18 Write failing trigger-default, opt-in, and configuration-change tests.
- [x] 2.19 Implement `session_end`, `completed_turn`, and `both` scope settings.
- [ ] 2.20 Write failing Hermes turn/session observation and restricted-context tests.
- [x] 2.21 Connect `sync_turn()` and `on_session_end()` to bounded durable source capture for configured triggers.
- [ ] 2.22 Write failing overlap, repeated-delivery, and uncovered-passage tests.
- [x] 2.23 Persist conversation coverage and candidate fingerprints across trigger jobs.
- [ ] 2.24 Write failing accepted/pending duplicate and empty-result tests.
- [x] 2.25 Filter unchanged candidates against authorized knowledge and finish empty jobs without proposals.
- [ ] 2.26 Write failing sourced correction and human-review tests.
- [x] 2.27 Preserve correction lineage and require human review for extracted text.
- [ ] 2.28 Write failing extraction-limit and queue-coalescing tests.
- [x] 2.29 Enforce configured bounds and preserve uncovered coordinates with inspectable diagnostics.

- [ ] 2.30 Write failing disposition tests for new, update, disputed, no-material, and combined classifications.
- [x] 2.31 Implement the shared read → compare → classify → propose contract with persisted reasons and candidate dispositions.
- [ ] 2.32 Write failing concept/alias matching, pending-candidate duplication, and related-target diagnostics tests.
- [ ] 2.33 Compare authorized knowledge and proposals, preserve conflict evidence and lineage, and identify related targets for review.
- [ ] 2.34 Write failing source-value fidelity and generated-answer grounding tests.
- [x] 2.35 Verify source passages before candidate construction and distinguish assertions from inferences.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.
- [ ] 3.4 Verify all trigger modes through the pinned Hermes runtime against isolated source and proposal services, including retry overlap and feature-disabled compatibility.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.


## Implementation verification record

Durable job, worker, model, configuration, and REST/MCP integration tests cover
coalesced observations, recovered leases, stable receipts, scoped evidence,
source purge and credential revocation during extraction, pending duplicate
suppression, pinned types, and human approval. The pinned Hermes runtime was
exercised against an isolated server with all three trigger settings. The Flutter
web app displayed the accepted Claim and its source passage after human approval.
These checks do not establish that every planned adversarial scenario passes.
Unchecked TDD tasks retain their original status because a passing regression does
not establish that its failing-first step was performed.
