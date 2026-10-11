# Memory health Specification

## Purpose
Expose safe, local status for Hermes automatic recall and memory writes.

## Requirements

### Requirement: Distinguish automatic operation outcomes
The provider SHALL expose a public `memory_health()` snapshot and a native `robotnotes_health` tool when native tools are enabled. The snapshot SHALL distinguish successful empty recall from authorization, network, and open-circuit failures, without changing the host recall-count contract. Mirror and transcript outcomes SHALL be independent. Status SHALL describe the latest started attempt for each operation, not delivery of earlier writes.

#### Scenario: Empty recall after recovery
- **WHEN** a search succeeds with no matches after an outage
- **THEN** recall health SHALL be `empty`
- **AND** the host recall indicator SHALL report no injected notes

#### Scenario: Failed automatic write
- **WHEN** an automatic mirror or transcript write fails
- **THEN** its status SHALL be `failed` with a safe error category
- **AND** the hook SHALL preserve graceful degradation
- **AND** health SHALL report retry support as unsupported until a delivery queue exists

### Requirement: Keep health local and content-free
Health inspection SHALL perform no network request. Snapshots and automatic-operation logs SHALL omit prompts, memory bodies, credentials, and server error text. Session changes SHALL reset outcomes, and stale asynchronous completions SHALL NOT replace the current session's health or a newer attempt's status.

#### Scenario: Session changes during background search
- **WHEN** a queued search completes after a session switch
- **THEN** it SHALL NOT change the new session's health

#### Scenario: Inspect an authorization failure
- **WHEN** a server response includes an authorization error with sensitive details
- **THEN** health SHALL expose only the `auth` category
- **AND** automatic-operation logs SHALL omit the response details
