## ADDED Requirements

### Requirement: Responsive proposal inbox and direct review

The client SHALL show the selected proposal beside the inbox on wide windows and as a full-page review on narrow windows. Selecting either new or existing knowledge SHALL open its changes, evidence, and discussion directly. Resizing SHALL retain the selected proposal and unsent comment. Filters SHALL expose active, accepted, and denied proposals. Loading, empty, and error states SHALL follow the app's shared presentation and controls SHALL follow platform conventions.

#### Scenario: Select an existing proposal
- **WHEN** a reviewer selects an existing-note proposal
- **THEN** the client SHALL show that proposal directly with verified accepted targets and proposed changes without requiring a second selection

#### Scenario: Resize during review
- **WHEN** a reviewer resizes between wide and narrow layouts with an unsent comment
- **THEN** the selected proposal and comment SHALL remain available

#### Scenario: Review new knowledge
- **WHEN** a reviewer selects a new-note proposal
- **THEN** the client SHALL show the draft without fetching an accepted placeholder note

### Requirement: Inline proposal actions preserve review context

The client SHALL provide permitted comments and decisions within the selected review, submit the displayed proposal revision, and disable duplicate submissions while pending. Failed actions SHALL retain the comment and display a recoverable error. Conflicts SHALL refresh the displayed proposal and accepted targets before permitting another decision. Accepted targets SHALL be verified against note version, content hash, block offsets, and block hash before decisions are enabled.

#### Scenario: Submit a comment
- **WHEN** a reviewer submits an inline comment successfully
- **THEN** the client SHALL refresh the same proposal and show the discussion without closing review

#### Scenario: Decision fails
- **WHEN** the server rejects a decision or comment
- **THEN** the client SHALL retain the draft and show the failure within review

#### Scenario: Accepted targets cannot be verified
- **WHEN** accepted content and block metadata do not match
- **THEN** the client SHALL show a retryable error and SHALL NOT enable review decisions

#### Scenario: Proposal targets an older accepted revision
- **WHEN** a block operation's expected revision differs from its accepted block revision, or a note deletion's proposal base version differs from the accepted note version
- **THEN** the client SHALL explain that the proposal needs an update and SHALL NOT enable review decisions
- **AND** an unrelated note version change SHALL NOT prevent review of a block operation whose expected block revision still matches
