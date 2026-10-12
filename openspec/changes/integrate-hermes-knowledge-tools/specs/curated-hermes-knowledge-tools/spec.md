## Purpose

Integrate Hermes tools and opt-in source capture implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Existing behavior remains compatible

Disabled capture and extraction SHALL preserve ordinary writes, scoped recall, identity destinations, read-only behavior, retries and health.

#### Scenario: Existing behavior remains compatible

- **WHEN** Hermes runs against the supported server with new features disabled
- **THEN** existing memory behavior SHALL remain unchanged

### Requirement: New tools obey capabilities

Hermes SHALL expose discovery, queries, inspection, validation and proposal submit/get/amend with server capability discovery.

#### Scenario: New tools obey capabilities

- **WHEN** a server lacks the knowledge contract or proposal permission
- **THEN** new calls SHALL report explicit diagnostics without direct-write fallback

### Requirement: Capture uses durable ingestion

Opt-in automatic observations SHALL use the shared source event namespace and retry semantics.

#### Scenario: Capture uses durable ingestion

- **WHEN** delivery response is lost and Hermes restarts
- **THEN** the outbox SHALL return to the same retained source identity without duplicates

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
