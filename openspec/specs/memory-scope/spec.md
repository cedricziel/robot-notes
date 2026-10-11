# Memory scope Specification

## Purpose
Organize Hermes memory mirrors and automatic recall with explicit identity destinations while preserving existing shared workflows.

## Requirements

### Requirement: Preserve shared defaults and opt into identity destinations
The provider SHALL default to shared mirrors at `Hermes/Memory` and `Hermes/User`, with existing vault-wide recall. Identity mode SHALL require explicit stable, lowercase ASCII path-safe `user_id` and `agent_id` values. It SHALL mirror user memory under `Hermes/users/<user_id>/User` and agent memory under `Hermes/agents/<agent_id>/Memory`. Actor attribution and host identity hints SHALL NOT determine these IDs.

#### Scenario: Two identities use one actor label
- **WHEN** two identity-mode providers use distinct configured IDs and the same actor label
- **THEN** their mirror destinations SHALL remain distinct

#### Scenario: Existing configuration
- **WHEN** a configuration omits memory scope
- **THEN** mirrors and recall SHALL retain their shared behavior

### Requirement: Scope automatic recall without granting access
Identity recall SHALL search only the configured user folder, agent folder, and optional shared folder, including subfolders. Results SHALL interleave these scopes deterministically, deduplicate IDs, and retain at most five notes. Failure of any scoped search SHALL prevent reporting partial recall as successful. Folder scope SHALL NOT be described as server authorization or knowledge authority; explicit tools SHALL remain subject to server credentials.

#### Scenario: Intentionally shared knowledge
- **WHEN** two providers configure the same shared folder and distinct identity folders
- **THEN** both SHALL recall matching shared notes alongside their own matching identity notes
- **AND** neither SHALL automatically recall the other's identity notes outside the selected folders

### Requirement: Never silently migrate shared memory
Changing memory scope SHALL NOT move, copy, merge, or delete existing notes. Documentation SHALL describe operator review and explicit copying before migration. Setup SHALL preserve manually configured scope fields.

#### Scenario: Enable identity scope with existing shared notes
- **WHEN** an operator enables identity mode
- **THEN** existing shared mirror notes SHALL remain unchanged
- **AND** subsequent mirror writes SHALL target the configured identity destinations
