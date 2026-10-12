## Purpose

Extract evidence-backed proposals from enabled sources implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Jobs recover without duplicates

Jobs SHALL durably store leases, state, checkpoints and proposal identities before checkpoint advancement.

#### Scenario: Jobs recover without duplicates

- **WHEN** the worker crashes after persisting its proposal
- **THEN** lease recovery SHALL reuse that proposal without duplicate candidate groups

### Requirement: Extraction cannot publish knowledge

The worker SHALL hold source-read and proposal permissions only and preserve passage evidence.

#### Scenario: Extraction cannot publish knowledge

- **WHEN** an extracted claim is generated
- **THEN** it SHALL remain a proposal until independent policy-controlled acceptance

### Requirement: Revocation stops processing

Workers SHALL recheck access, source availability and extraction enablement before reads and submissions.

#### Scenario: Revocation stops processing

- **WHEN** extraction is disabled or source access revoked while running
- **THEN** further protected reads and new proposal submissions SHALL stop

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
