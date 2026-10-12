## Purpose

Gate release on isolated Hermes and Flutter verification implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Isolation is mandatory

Verification SHALL use a throwaway real server, real plugin tools and memory-provider interface with no inherited production configuration.

#### Scenario: Isolation is mandatory

- **WHEN** safe isolation cannot be established
- **THEN** the gate SHALL remain unverified and no release claim SHALL be made

### Requirement: Complete lifecycle is verified

The gate SHALL cover disabled legacy memory, opt-in capture, extraction, absent pending recall, separately authorized acceptance and accepted recall.

#### Scenario: Complete lifecycle is verified

- **WHEN** the isolated lifecycle executes
- **THEN** recorded results SHALL prove each phase against persisted server state

### Requirement: Recovery and compatibility are verified

The gate SHALL exercise lost responses, restart, duplicate prevention, read-only behavior, unsupported capabilities and denied proposals.

#### Scenario: Recovery and compatibility are verified

- **WHEN** the real plugin retries interrupted delivery and submission
- **THEN** identities SHALL remain stable without accepted-write fallback

### Requirement: Release evidence identifies tested artifacts

Evidence SHALL record server and plugin revisions, Hermes runtime and contract versions, commands and cleanup.

#### Scenario: Release evidence identifies tested artifacts

- **WHEN** all required checks pass
- **THEN** the release gate SHALL explicitly identify the supported tested pair

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available


### Requirement: Every shared Hermes operation is exercised

The release gate SHALL exercise list_knowledge_types, get_knowledge_type, query_knowledge, inspect_source, validate_knowledge_candidate, propose_knowledge, get_knowledge_proposal, and amend_knowledge_proposal through the real registered Hermes tools against the isolated real server. Discovery SHALL cover both listing and reading a pinned definition.

#### Scenario: Tool coverage is incomplete

- **WHEN** any named operation lacks a passing live-server verification result
- **THEN** the release gate SHALL remain incomplete regardless of other successful checks
