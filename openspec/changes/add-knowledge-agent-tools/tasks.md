## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing capability discovery and type endpoint tests.
- [ ] 2.2 Implement discovery and machine-readable tool schemas.
- [ ] 2.3 Write failing accepted-only property and relation query tests.
- [ ] 2.4 Index accepted entry IDs, revisions, types, and primitive properties.
- [ ] 2.5 Index accepted named relations by source and target identity.
- [ ] 2.6 Update entry and relation indexes after one accepted mutation group.
- [ ] 2.7 Rebuild indexes from accepted filesystem snapshots with network disabled.
- [ ] 2.8 Write failing hidden path and traversal bound tests.
- [ ] 2.9 Traverse one authorized outgoing relation hop.
- [ ] 2.10 Add a second hop with deduplicated stable IDs.
- [ ] 2.11 Apply node budget and return explicit truncation.
- [ ] 2.12 Exclude hidden targets before paths and counts are accumulated.
- [ ] 2.13 Write failing cursor revision and query binding tests.
- [ ] 2.14 Implement pagination and stale cursor responses.
- [ ] 2.15 Write failing REST and MCP parity tests.
- [ ] 2.16 Expose source inspection and validation REST operations.
- [ ] 2.17 Expose proposal submit, inspect, and amend REST operations.
- [ ] 2.18 Bind source inspection and validation MCP tools to shared services.
- [ ] 2.19 Bind proposal submit, inspect, and amend MCP tools to shared services.
- [ ] 2.20 Run adapter contract checks and commit tools.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
