## ADDED Requirements

### Requirement: Optional completed-turn evidence
The provider SHALL disable evidence capture by default. When enabled in a permitted primary context, it SHALL durably queue supported JSON messages from completed turns, preserve supplied stable message identities, and identify snapshots by canonical JSON SHA-256.

#### Scenario: Raw tool evidence is captured
- **WHEN** Hermes supplies a completed turn containing tool results and structured JSON message parts
- **THEN** the provider SHALL preserve the supplied objects without readable-transcript truncation
- **AND** retries and restart SHALL retain the same snapshot identity

#### Scenario: Host omits raw messages
- **WHEN** a completed-turn callback provides only user and assistant text
- **THEN** the archive SHALL explicitly identify the snapshot as a text fallback
- **AND** SHALL not claim tool evidence was captured

### Requirement: Fail-closed pre-compression checkpoint
The provider SHALL advertise checkpoint API v2 only when evidence capture is enabled and a primary write client and durable evidence queue exist. Checkpoint success SHALL require durable remote acknowledgement of pending raw snapshots and the supplied host-normalized evidence checkpoint.

#### Scenario: Pending raw evidence cannot be acknowledged
- **WHEN** the server fails or acknowledges a different snapshot
- **THEN** the checkpoint SHALL raise an error
- **AND** failed raw evidence SHALL remain queued across restart

#### Scenario: Non-primary or disabled provider
- **WHEN** capture is disabled or the agent context forbids writes
- **THEN** the provider SHALL advertise only legacy checkpoint API v1

### Requirement: Session lineage remains explicit
Evidence SHALL retain the session ID supplied at capture and first-write parent, reset, and rewind metadata separately from the digest identity.

#### Scenario: Branch follows a failed capture
- **WHEN** the provider switches to a branch while evidence remains queued
- **THEN** old evidence SHALL retain its original session
- **AND** new evidence SHALL identify the branch and supplied lineage
