## Purpose

Store reusable types as curated filesystem documents implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Type files preserve semantics

Type documents SHALL encode stable identity, version, parents, constraints, relations, guidance and origin using the umbrella file contract.

#### Scenario: Type files preserve semantics

- **WHEN** a local Claim definition is decoded and encoded
- **THEN** its enforced constraints and guidance SHALL survive without reusing the ordinary type discriminator

### Requirement: Candidate edits cannot activate themselves

Unreviewed filesystem edits SHALL NOT replace accepted definitions even after restart.

#### Scenario: Candidate edits cannot activate themselves

- **WHEN** an external file changes required fields before acceptance
- **THEN** validation SHALL continue using the prior accepted snapshot

### Requirement: Type indexes rebuild offline

Indexes SHALL reconstruct pinned versions from files and retained snapshots without remote fetching.

#### Scenario: Type indexes rebuild offline

- **WHEN** derived type indexes are removed
- **THEN** rebuild SHALL restore the same definitions and constraints

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available


### Requirement: Type review is separate from entry proposals

A type-definition review service SHALL validate, propose, inspect, amend, and accept definition candidates using the existing review core. Proposal authority SHALL NOT grant activation authority. Bulk adoption candidates SHALL group the artifact, manifest, imported terms, and local definitions. Authorized acceptance SHALL revalidate policy and versions and publish the complete group atomically with retained history. Initial knowledge-entry proposal operations SHALL remain limited to knowledge entries.

#### Scenario: Importer submits a bulk candidate

- **WHEN** the importer submits an adoption containing a manifest and dependent type definitions
- **THEN** they SHALL remain candidates until authorized type review acceptance publishes the complete valid group atomically

#### Scenario: Agent attempts type activation

- **WHEN** a proposal-only agent attempts to accept a definition candidate
- **THEN** the service SHALL deny activation while retaining the proposal for authorized review
