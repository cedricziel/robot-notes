## Purpose

Enforce curated policy across all adapters implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Policy cannot be bypassed

All server adapters SHALL enforce effective read and mutation policy using credential-derived principals. Database membership SHALL NOT alter approval policy.

#### Scenario: Policy cannot be bypassed

- **WHEN** an agent lacking accepted-edit authority writes curated content through append, properties, or restore
- **THEN** the server SHALL deny each operation and leave accepted content unchanged

### Requirement: Policy follows moves

Moves SHALL recalculate effective policy and invalidate stale acceptance eligibility.

#### Scenario: Policy follows moves

- **WHEN** a note moves to a stricter folder
- **THEN** subsequent operations SHALL use destination policy without permission escalation

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available
