## Purpose

Validate and accept atomic typed candidate groups implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Complete candidates enforce constraints

Validation SHALL apply all sets, unsets, replacements and relation operations before checking pinned type constraints.

#### Scenario: Complete candidates enforce constraints

- **WHEN** an update removes a required field or last required relation
- **THEN** acceptance SHALL fail and preserve accepted revisions

### Requirement: Groups resolve new targets atomically

Compatible intra-group targets SHALL be allowed for required and optional relations.

#### Scenario: Groups resolve new targets atomically

- **WHEN** a group creates Evidence and Claim or Person and Project together
- **THEN** acceptance SHALL publish every entry atomically or none

### Requirement: Concurrent integrity is serialized

Relation acceptance, target deletion and migration SHALL share a transactional integrity boundary.

#### Scenario: Concurrent integrity is serialized

- **WHEN** incoming relation acceptance races with target deletion
- **THEN** both SHALL NOT commit leaving an invalid accepted relation

### Requirement: Proposal retries preserve identity

Keys SHALL be scoped by vault, principal and operation with canonical digest and purge tombstones.

#### Scenario: Proposal retries preserve identity

- **WHEN** submission is retried after a lost response
- **THEN** the original proposal identity SHALL be returned without duplication

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
