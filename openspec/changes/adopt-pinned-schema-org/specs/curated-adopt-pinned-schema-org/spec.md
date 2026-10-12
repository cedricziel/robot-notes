## Purpose

Bulk-adopt a pinned published Schema.org release implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Imports pin a published snapshot

Adoption SHALL record release identifier, artifact source and digest and SHALL reject moving development sources.

#### Scenario: Imports pin a published snapshot

- **WHEN** an authorized operator previews a pinned release
- **THEN** the preview SHALL enumerate supported terms, collisions, dependencies and unsupported constructs

### Requirement: Bulk activation preserves local constraints

Reviewed adoption SHALL make the supported vocabulary available together without treating suggested properties as mandatory.

#### Scenario: Bulk activation preserves local constraints

- **WHEN** the same snapshot is adopted twice
- **THEN** definitions SHALL NOT duplicate and local required fields SHALL remain explicit

### Requirement: Upgrades require impact review

New snapshots SHALL preview affected definitions and entries and retain old pinned versions.

#### Scenario: Upgrades require impact review

- **WHEN** an upgrade changes an inherited term
- **THEN** existing accepted entries SHALL retain their prior versions until reviewed migration

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
