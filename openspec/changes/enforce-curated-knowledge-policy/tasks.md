## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Verification and integration audit

- [ ] 2.1 Confirm PR #391 service and documentation match the existing policy foundation.
- [ ] 2.2 Run existing policy inheritance and trusted-principal regression tests.
- [ ] 2.3 Run existing property, append, move, and restore authorization regressions.
- [ ] 2.4 Run existing snippets, database row, and WebSocket read-access regressions.
- [ ] 2.5 Audit type review and activation authorization tests in the owning slice.
- [ ] 2.6 Audit source ingestion and inspection authorization tests in the owning slice.
- [ ] 2.7 Audit typed proposal and query traversal authorization tests in the owning slices.
- [ ] 2.8 Audit extraction credential and revocation tests in the owning slice.
- [ ] 2.9 Record demonstrated gaps; for each, write one failing regression before a focused fix.
- [ ] 2.10 Verify each focused fix reuses the existing policy service and record results.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
