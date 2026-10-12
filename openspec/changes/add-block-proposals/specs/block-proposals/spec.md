## ADDED Requirements

### Requirement: Pending proposals stay separate
The server SHALL persist versioned existing-note proposals and explicit new-note drafts without publishing candidate content in normal notes, search, links, database rows, embeddings, or recall. New-note drafts SHALL reserve identity without creating canonical Markdown.

#### Scenario: Agent submits a draft
- **WHEN** an authorized agent proposes a new note in a curated folder
- **THEN** the draft is inspectable as a proposal and normal accepted retrieval remains unchanged

### Requirement: Atomic multi-block acceptance
Approval SHALL accept all reviewed operations under shared policy and note mutation locks. Disjoint newer accepted edits SHALL merge when all touched block and gap checks remain fresh. Same-block, structural, or ambiguous changes SHALL invalidate review rather than guessing correspondence.

#### Scenario: Disjoint concurrent updates
- **WHEN** two proposals affect distinct current blocks
- **THEN** each can be accepted without overwriting the other's accepted change

#### Scenario: Same insertion gap
- **WHEN** an accepted update changes the insertion anchors of another proposal
- **THEN** that proposal requires re-review before acceptance

### Requirement: Durable review and provenance
Proposal amendments, comments, decisions, evidence references, and accepted block provenance SHALL remain immutable audit history until explicit authorized purge. Accepted publication SHALL recover canonical content, revision, map, provenance, and proposal state as one journaled operation.

#### Scenario: Interrupted acceptance
- **WHEN** acceptance fails after canonical publication
- **THEN** content and proposal inspection fail closed until restart replay publishes the same intended revision and decision

### Requirement: Trusted review authority
Submission SHALL require propose authority and final human decisions SHALL require trusted review authority. Known agents SHALL not gain human authority through actor labels or elevated agent scopes. Acceptance permits SHALL be issued only by authorized review or verified automatic eligibility.

#### Scenario: Agent requests human approval authority
- **WHEN** a known agent credential calls the review decision endpoint
- **THEN** the server refuses the decision without changing accepted content

### Requirement: Conservative automatic eligibility
Automatic acceptance SHALL require explicit effective policy, authorized submission, validated accessible evidence, current blocks, unchanged effective policy, and a verified supported non-conflict result. Unknown semantic eligibility SHALL remain pending for human review.

#### Scenario: Evidence exists but claims changed
- **WHEN** a proposal changes arbitrary claims and only proves that evidence references exist
- **THEN** the server does not infer semantic consistency or automatically accept the proposal


#### Scenario: Verified source attachment only
- **WHEN** effective policy permits automatic acceptance and every operation attaches nonempty resolved accessible immutable evidence without changing accepted text
- **THEN** the server may accept only the source linkage and records verified automatic eligibility

#### Scenario: Restore reverses active source attachment
- **WHEN** a human restores an accepted snapshot from before an automatic source attachment
- **THEN** the new accepted snapshot has the selected source-link state and the original accepted proposal remains historical until explicit purge

#### Scenario: Source expires during automatic verification
- **WHEN** an archive reference becomes unavailable after durable proposal submission
- **THEN** the proposal remains pending and accepted content stays unchanged

### Requirement: Review discovery and anchored comments
The server SHALL expose a readable vault review index with title, path, and new-note target metadata. Inspection SHALL include only the caller's allowed review actions and retained candidate versions accessible at their historical target locations. Accepted-block comments SHALL use separate immutable threads without fake proposal records.

#### Scenario: New-note draft is globally discoverable
- **WHEN** a readable new-note proposal exists without canonical Markdown
- **THEN** the vault review index lists its reserved note identity and inspection exposes its exact draft body

#### Scenario: Reader cannot append comments
- **WHEN** a caller has only read authority at the target
- **THEN** immutable comment append is refused until propose or trusted review authority is granted
