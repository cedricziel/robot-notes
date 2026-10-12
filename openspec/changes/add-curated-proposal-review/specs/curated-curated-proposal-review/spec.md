## Purpose

Persist block proposals and review decisions implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Review preserves lineage

Proposals SHALL retain principal, evidence, accepted bases, touched block revisions, amendments and review decisions outside normal recall.

#### Scenario: Review preserves lineage

- **WHEN** an author amends reviewed content
- **THEN** prior versions SHALL remain inspectable and approvals for changed content SHALL be invalidated

### Requirement: Block acceptance checks freshness

Acceptance SHALL atomically compare touched block revisions and effective policy.

#### Scenario: Block acceptance checks freshness

- **WHEN** a proposal targets unchanged blocks while unrelated blocks changed
- **THEN** acceptance SHALL remain possible without overwriting unrelated edits

### Requirement: Accepted recall excludes pending data

Pending, denied and historical review data SHALL require explicit authorized inspection.

#### Scenario: Accepted recall excludes pending data

- **WHEN** ordinary search runs while a proposal is pending
- **THEN** proposal text SHALL NOT appear as accepted knowledge

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
