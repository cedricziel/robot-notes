## Purpose

Expose accepted queries and shared agent tools implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Discovery describes accepted definitions

Discovery SHALL expose accepted guidance and effective pinned constraints and advertise contract version and operations.

#### Scenario: Discovery describes accepted definitions

- **WHEN** an agent requests a type version
- **THEN** it SHALL receive accepted definition content without pending edits

### Requirement: Queries are bounded and access filtered

Queries SHALL use accepted records, depth at most two, at most 200 nodes and pages, and revision-bound cursors.

#### Scenario: Queries are bounded and access filtered

- **WHEN** a path crosses an inaccessible node or continuation becomes stale
- **THEN** hidden paths SHALL be omitted and stale continuation SHALL return cursor_stale

### Requirement: Adapters share errors and permissions

REST and MCP SHALL invoke identical validation and proposal services with common structured errors.

#### Scenario: Adapters share errors and permissions

- **WHEN** an agent probes inaccessible source references through validation
- **THEN** responses SHALL not reveal whether hidden objects exist

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
