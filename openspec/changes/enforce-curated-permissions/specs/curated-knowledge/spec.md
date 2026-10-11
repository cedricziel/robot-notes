## ADDED Requirements

### Requirement: Trusted action authorization
The server SHALL authorize read, propose, review, edit, policy, and purge using stable authenticated principal identity, selected-vault rights, explicit capabilities, and effective access lists. Actor labels SHALL NOT grant authority. Missing or expired request contexts SHALL deny access. Non-read actions SHALL require effective read access.

#### Scenario: An agent requests accepted editing with elevated scopes
- **WHEN** a known agent credential has ordinary write and knowledge edit scopes
- **THEN** it cannot directly modify accepted curated content or perform final human review, policy management, or purge

#### Scenario: A legacy operator request identifies agent origin
- **WHEN** an authenticated operator request supplies the restrictive agent-origin header
- **THEN** its identity is preserved but curated direct editing and human-only actions are denied

### Requirement: Server-owned inherited policy
Curated designation and action ACLs SHALL be stored outside editable note content. Policies SHALL inherit from root and ancestor folders, with note overrides. Omitted fields SHALL inherit, empty action lists SHALL deny, and wildcard access SHALL remain capability-gated. Policy updates SHALL require conditional revision matching and trusted human policy authority.

#### Scenario: Editable content attempts to remove designation
- **WHEN** note properties or body claim that a curated note is ordinary
- **THEN** effective server policy remains curated

#### Scenario: A move crosses effective protection boundaries
- **WHEN** a caller moves a note between different effective protection rules
- **THEN** the server requires policy authority at both source and destination before publishing the move

### Requirement: Complete source and transport protection
REST, MCP, and WebSocket adapters SHALL enforce the shared authorizer. Read filtering SHALL occur before limits, pagination, and aggregate counts. Historical reads SHALL require current or tombstone policy and retained-path policy. Attachment reads SHALL honor both physical location and accepted referencing-note policy. Uploads SHALL reject canonical note imports and revalidate staged issuer, vault, destination, and current permissions before publication.

#### Scenario: A private note is reachable through an attachment or old revision
- **WHEN** a caller lacks the accepted note's current read permission
- **THEN** the server withholds its protected attachment and historical content

#### Scenario: An upload attempts to reuse a curated note identity
- **WHEN** a file upload contains canonical note frontmatter under another filename
- **THEN** publication is rejected and restart cannot import the uploaded alias as accepted content

### Requirement: Required accepted history
Curated designation SHALL initialize accepted history and stable current block identities before policy publication. A durable required-history marker SHALL survive editable property changes and explicit purge. Existing immutable legacy snapshots SHALL remain unchanged when a new no-op accepted revision is necessary. An incomplete accepted transaction SHALL block content and policy mutation until recovery.

#### Scenario: Live curated history is purged and the server restarts
- **WHEN** an authorized human purges history for a live curated note
- **THEN** older revisions and review records are erased, while the current accepted snapshot, block map, and active provenance survive purge and restart

### Requirement: Honest capability inspection
Existing and prospective note inspection SHALL expose the caller's effective action verbs and integer policy revision without creating accepted placeholders. Curated text proposals SHALL report human approval required. Only existing curated notes with evidence-no-conflict approval SHALL advertise the verified-source-attachment automatic class; raw evidence collections SHALL NOT advertise accepted-note automatic classes.

#### Scenario: A proposal-only agent inspects a curated target
- **WHEN** the agent reads its target permissions
- **THEN** the response reports proposal authority without direct accepted-edit or human-review authority
