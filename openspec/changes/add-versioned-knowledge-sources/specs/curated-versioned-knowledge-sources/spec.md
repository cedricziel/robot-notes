## Purpose

Ingest immutable sources and revision-specific Evidence implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Ingestion is opt-in and scoped

Automatic capture SHALL require enabled adapter and scope and credential-derived authority.

#### Scenario: Ingestion is opt-in and scoped

- **WHEN** capture-disabled Hermes delivers an observation
- **THEN** no source or extraction job SHALL be created

### Requirement: Delivery retries are isolated

Source deduplication SHALL follow the umbrella key and digest contract and persist transactionally.

#### Scenario: Delivery retries are isolated

- **WHEN** different adapters reuse an event ID or a retry changes requested scope
- **THEN** adapters SHALL remain independent and changed-scope retries SHALL conflict

### Requirement: Evidence pins original material

Evidence SHALL resolve an immutable source revision and validated locator.

#### Scenario: Evidence pins original material

- **WHEN** a cited source changes or is purged
- **THEN** references SHALL retain the old revision or report unavailable without redirecting

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
