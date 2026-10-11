## ADDED Requirements

### Requirement: Separate durable evidence storage
The server SHALL store immutable JSON snapshots outside accepted notes and ordinary search indexes, scoped to the selected vault. The server SHALL acknowledge a PUT only after the snapshot has durably committed.

#### Scenario: Evidence survives restart
- **WHEN** a PUT with a valid SHA-256 digest and supported snapshot succeeds
- **THEN** the same snapshot SHALL be readable after reopening the vault
- **AND** ordinary note listings and search SHALL exclude that evidence

#### Scenario: Retry preserves original metadata
- **WHEN** the same snapshot is submitted again
- **THEN** its original expiry and lineage SHALL remain unchanged

### Requirement: Independent evidence retention and purge
Evidence retention SHALL accept integer days from 1 through 3650. Expired evidence SHALL be unavailable. Administrative purge SHALL erase payload and lineage, and delayed retries SHALL not restore them.

#### Scenario: Erased evidence is retried
- **WHEN** an expired or administratively purged digest is submitted again
- **THEN** the server SHALL return an error rather than store the erased snapshot again

#### Scenario: Agent attempts administrative purge
- **WHEN** an OAuth writer attempts DELETE on evidence
- **THEN** the server SHALL deny the purge

### Requirement: Vault-scoped evidence authorization
Evidence capture SHALL require the existing REST write scope. Evidence inspection SHALL require the existing REST read scope. Both SHALL enforce the selected vault grant.

#### Scenario: Credential reads outside its vault grant
- **WHEN** a credential requests evidence in an unauthorized vault
- **THEN** the server SHALL deny access before reading evidence
