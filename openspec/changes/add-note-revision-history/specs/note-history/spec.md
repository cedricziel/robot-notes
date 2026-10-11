## ADDED Requirements

### Requirement: Opt-in accepted history
The server SHALL retain accepted content for notes opted in with `history: true`, outside ordinary note search. History SHALL remain until explicit purge and SHALL NOT expire automatically.

#### Scenario: Replace accepted content
- **WHEN** an opted-in note is updated
- **THEN** prior accepted content remains inspectable and the new version is retained

#### Scenario: Ordinary note deletion
- **WHEN** a note without opt-in or existing history is deleted
- **THEN** no history is created

### Requirement: Recover interrupted commits
The server SHALL complete durable pending history operations before indexing. Pending operations SHALL NOT appear as accepted revisions before application.

#### Scenario: Crash before publication
- **WHEN** the process stops after writing pending intent but before publishing canonical content
- **THEN** restart completes that operation and rebuilds stale search data

### Requirement: Restore and purge
Restore SHALL create a new version without overwriting a different note. Explicit purge SHALL remove retained revisions and tombstones without deleting a live canonical note.

#### Scenario: Restore deleted note
- **WHEN** an authorized writer restores a retained revision using the latest deletion version
- **THEN** the same note ID returns with a newer version and becomes searchable

#### Scenario: Permanent erasure
- **WHEN** an authorized administrator purges a deleted note's history
- **THEN** that history cannot be inspected or restored

### Requirement: Historical content authorization
Historical reads and mutations SHALL enforce existing vault and scope checks. Purge SHALL additionally require vault-management authority.

#### Scenario: Wrong vault grant
- **WHEN** a credential without access to the selected vault requests history
- **THEN** the server rejects the request without returning retained content
