## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing candidate set and unset validation tests.
- [ ] 2.2 Apply property sets and unsets to one candidate entry.
- [ ] 2.3 Check required primitive properties and list cardinalities.
- [ ] 2.4 Resolve pinned inherited constraints for each candidate.
- [ ] 2.5 Validate relation target type and cardinality across the group.
- [ ] 2.6 Write failing local reference and optional relation group tests.
- [ ] 2.7 Resolve candidate-local identities and Evidence references.
- [ ] 2.8 Write failing proposal key reuse and amendment revision tests.
- [ ] 2.9 Canonicalize proposal payload and compare consumed keys.
- [ ] 2.10 Persist proposal revision and response in one transaction.
- [ ] 2.11 Return persisted result after an identical retry.
- [ ] 2.12 Preserve consumed-key tombstones after authorized purge.
- [ ] 2.13 Write failing concurrent acceptance and deletion tests.
- [ ] 2.14 Serialize checks across affected identities.
- [ ] 2.15 Inject failure during multi-entry publication and test recovery.
- [ ] 2.16 Persist one group mutation journal before any document publication.
- [ ] 2.17 Stage candidate files and retained snapshots for one group.
- [ ] 2.18 Publish staged files while blocking reads of incomplete groups.
- [ ] 2.19 Replay committed group publication after interruption.
- [ ] 2.20 Reject uncommitted groups and remove staged files during recovery.
- [ ] 2.21 Run atomic proposal checks and commit the mutation slice.
- [ ] 2.22 Write failing type upgrade preview and coherent migration tests.
- [ ] 2.23 Compute affected entries for a proposed type version.
- [ ] 2.24 Return validation diagnostics for each affected candidate.
- [ ] 2.25 Require review authorization and expected bases for migration.
- [ ] 2.26 Publish a validated migration group using existing atomic publication.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
