## ADDED Requirements
### Requirement: Explicit review workspace
The application SHALL keep accepted Markdown in the existing note view and expose proposals, block comments, history, and policy through an explicit review workspace.

#### Scenario: Pending proposal
- **WHEN** a note has a pending proposal
- **THEN** the normal note view shows only accepted content
- **AND** the review workspace shows the pending operations and evidence

### Requirement: Authorized review controls
The application SHALL use server-reported permissions and record revisions for review actions.

#### Scenario: Stale decision
- **WHEN** the server rejects a decision because its record revision changed
- **THEN** the application refreshes review state and requires another user decision
- **AND** it does not retry approval automatically

### Requirement: Retained accepted history
Authorized users SHALL inspect accepted versions and restore a version as a new accepted revision.

#### Scenario: Restore
- **WHEN** an authorized user restores an earlier version
- **THEN** the application submits the current accepted version as a concurrency precondition
- **AND** reloads accepted content after success

### Requirement: Discover unaccepted new knowledge
The application SHALL expose an explicit vault proposal index for new-note drafts without creating accepted placeholder notes.

#### Scenario: Review new-note draft
- **WHEN** an agent proposes a new institutional note
- **THEN** an authorized reviewer can inspect its content and evidence through the proposal index
- **AND** approval uses the proposal record revision without requiring an accepted note to exist first
