## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing service authorization tests for direct edit and proposal-only credentials.
- [ ] 2.2 Implement effective vault and folder policy resolution.
- [ ] 2.3 Write failing adapter tests for property, append, move and restore bypasses.
- [ ] 2.4 Route mutation adapters through the shared authorization service.
- [ ] 2.5 Write failing read tests for snippets, rows and WebSocket events.
- [ ] 2.6 Filter all read adapters through effective access.
- [ ] 2.7 Run adapter integration checks and commit the policy slice.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Implementation tasks are bounded to 15-minute increments; split any larger step into named substeps before applying it. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
