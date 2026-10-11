## ADDED Requirements

### Requirement: Optional durable automatic delivery
The provider SHALL allow automatic memory mirrors and session notes to use an opt-in persistent bounded outbox. Writes SHALL retain order and survive restart. Queues SHALL be isolated by destination and credential identity, and only permitted primary contexts SHALL replay them.

#### Scenario: Server failure followed by restart
- **WHEN** an automatic write fails because the server is unavailable and the provider restarts
- **THEN** the pending write SHALL remain available for delivery to the original destination

#### Scenario: Queue capacity is exceeded
- **WHEN** a new operation would exceed the queue limits
- **THEN** the provider SHALL report failure through memory health
- **AND** SHALL not evict an older operation

### Requirement: Retry-safe prepared effects
The provider SHALL persist a prepared effect before delivering a note mutation. Repeated delivery SHALL not reapply a selector or duplicate an accepted addition after an ambiguous acknowledgement. Changes that cannot be established as the intended accepted effect SHALL block automatic replay.

#### Scenario: Remove acknowledgement is lost
- **WHEN** the server accepts a removal but its acknowledgement is lost
- **THEN** replay SHALL recognize the prepared content as accepted
- **AND** SHALL not remove another matching entry

#### Scenario: Concurrent edit follows ambiguous delivery
- **WHEN** the destination content changes before a retry can establish acceptance
- **THEN** automatic replay SHALL stop with a blocked operation

### Requirement: Inspectable bounded retry state
Memory health SHALL expose pending, blocked, failure reason, and expired operation counts without note content or credentials. Transient network and server errors SHALL retry on subsequent delivery triggers. Permanent errors SHALL require explicit retry after correction.

#### Scenario: Permanent denial precedes another operation
- **WHEN** delivery receives a permanent authorization failure
- **THEN** the operation and later operations SHALL remain queued without automatic replay
