## Purpose

Review typed knowledge in the existing editor implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Authoring exposes guidance and errors

The editor SHALL display accepted type guidance and actionable structural diagnostics without forcing prose templates.

#### Scenario: Authoring exposes guidance and errors

- **WHEN** an author edits a Decision missing rationale
- **THEN** the UI SHALL identify the requirement while preserving the draft

### Requirement: Review is explicit and revision aware

Review SHALL expose group operations, source locators, stale anchors and expected proposal revision.

#### Scenario: Review is explicit and revision aware

- **WHEN** an authorized reviewer inspects and accepts a valid group
- **THEN** accepted views SHALL update coherently and stale approval SHALL be rejected

### Requirement: Default display stays accepted

Ordinary editor and search SHALL not present pending suggestions as accepted knowledge.

#### Scenario: Default display stays accepted

- **WHEN** an extraction proposal is waiting for review
- **THEN** users SHALL enter explicit review mode to inspect it

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
