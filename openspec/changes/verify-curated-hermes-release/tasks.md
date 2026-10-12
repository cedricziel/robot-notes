## 1. Preparation

- [ ] 1.1 Confirm verified dependency contracts and inspect applicable umbrella requirements.
- [ ] 1.2 Identify affected service and adapter boundaries and select the first failing regression.

## 2. Implementation

- [ ] 2.1 Write failing harness isolation and cleanup guard tests.
- [ ] 2.2 Create a throwaway vault and datastore with test credentials.
- [ ] 2.3 Reserve unique HTTP and VM-service ports and start server.
- [ ] 2.4 Create an isolated Hermes home and durable outbox.
- [ ] 2.5 Verify cleanup terminates only harness-owned processes.
- [ ] 2.6 Add feature-disabled memory and read-only live checks.
- [ ] 2.7 Add deterministic captured source and pending proposal flow.
- [ ] 2.8 Add separate test reviewer acceptance and accepted recall checks.
- [ ] 2.9 Inject lost source-delivery response and verify one revision.
- [ ] 2.10 Restart Hermes during pending outbox delivery and verify recovery.
- [ ] 2.11 Inject lost proposal response and verify original proposal ID.
- [ ] 2.12 Restart worker after proposal persistence and verify no duplicate.
- [ ] 2.13 Add capability and permission failure live checks.
- [ ] 2.14 Start an isolated app profile connected to the disposable server.
- [ ] 2.15 Edit one typed draft and inspect validation diagnostics.
- [ ] 2.16 Review and accept one group using the test reviewer.
- [ ] 2.17 Reload app and verify accepted content persisted.
- [ ] 2.18 Record supported server, plugin, and Flutter app revisions, runtime versions, and results.
- [ ] 2.19 Update project-local verify guidance with repeatable commands.
- [ ] 2.20 Clean up processes and state and commit verification tooling.
- [ ] 2.21 Exercise actual pinned Schema.org adoption against the isolated real server.
- [ ] 2.22 Exercise `list_knowledge_types` through the real registered Hermes tool against the real server.
- [ ] 2.23 Exercise `get_knowledge_type` through the real registered Hermes tool against the real server.
- [ ] 2.24 Exercise `query_knowledge` through the real registered Hermes tool against the real server.
- [ ] 2.25 Exercise `inspect_source` through the real registered Hermes tool against the real server.
- [ ] 2.26 Exercise `validate_knowledge_candidate` through the real registered Hermes tool against the real server.
- [ ] 2.27 Exercise `propose_knowledge` through the real registered Hermes tool against the real server.
- [ ] 2.28 Exercise `get_knowledge_proposal` through the real registered Hermes tool against the real server.
- [ ] 2.29 Exercise `amend_knowledge_proposal` through the real registered Hermes tool against the real server.
- [ ] 2.30 Verify unsupported-capability diagnostics with a controlled older contract fixture.

## 3. Verification and delivery

- [ ] 3.1 Run relevant formatting, lint, and focused tests; fix failures.
- [ ] 3.2 Run strict OpenSpec validation and review data migration and permission coverage.
- [ ] 3.3 Record verification evidence and commit the final coherent slice with a conventional message.

## Definition of Done

All delta scenarios pass, applicable umbrella constraints remain satisfied, dependencies are verified, and ordinary workflows remain usable. Each task targets one bounded behavior or one verification result and is estimated at no more than 15 minutes. Stop and re-plan any task that exceeds its stated boundary. TDD tasks introduce a failing regression before changing behavior. Use atomic conventional commits and independently verifiable PRs. Full curated release readiness remains gated by isolated Hermes and Flutter verification, not by planning completion.
