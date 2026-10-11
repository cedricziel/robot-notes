## ADDED Requirements

### Requirement: Curated knowledge uses ordinary accepted notes

The system SHALL allow an ordinary note to be designated curated knowledge while preserving Markdown content, existing editing, folder organization, and database membership. Accepted content SHALL remain the normal note representation.

#### Scenario: Designating existing knowledge

- **GIVEN** an ordinary note in a folder and database
- **WHEN** an authorized user designates it curated knowledge
- **THEN** its accepted Markdown, folder, and database membership SHALL remain available through existing note workflows

### Requirement: Stable blocks support precise review

The system SHALL persist opaque block identities and accepted block revisions for curated notes. It SHALL preserve identity for unchanged and unambiguously moved blocks and SHALL require re-review when reconciliation is ambiguous. Block metadata SHALL NOT modify accepted Markdown formatting.

#### Scenario: Moving an unchanged block

- **WHEN** an authorized save unambiguously moves an unchanged block
- **THEN** its identity SHALL remain stable and attached review comments SHALL remain associated with it

#### Scenario: Ambiguous block correspondence

- **WHEN** a split, merge, duplicate, or unsupported rewrite makes a reviewed block's correspondence ambiguous
- **THEN** the system SHALL flag affected anchors and proposals for re-review rather than attach them by guesswork

### Requirement: Proposals contain evidence and revisioned review activity

Agents SHALL submit proposed curated-content changes through a proposal workflow. A proposal SHALL record its author principal, accepted base, touched blocks, proposed operations, supporting evidence, and review history. Authorized reviewers SHALL be able to approve, deny, comment, and request changes. Amendments SHALL retain earlier versions and invalidate approvals for changed proposal content.

#### Scenario: Requesting changes

- **WHEN** an authorized reviewer requests changes to a proposal
- **THEN** the proposal SHALL retain the request and remain outside accepted content until an eligible revised proposal is accepted

#### Scenario: Commenting on an earlier block revision

- **WHEN** a reviewed block changes or is removed
- **THEN** prior comments SHALL remain inspectable with their revision context and stale or orphaned anchor state

### Requirement: Approval defaults to humans and can be configured

Institutional knowledge SHALL require explicitly granted human approval by default. Effective note or folder policy MAY allow automatic acceptance of authorized, evidence-backed, non-conflicting updates. Automatic acceptance SHALL record the policy and eligibility checks used. Unknown eligibility, unresolved evidence, changed targets, or conflicts SHALL prevent automatic acceptance.

#### Scenario: Default institutional proposal

- **WHEN** an agent proposes an institutional update without an explicit automatic-acceptance policy
- **THEN** it SHALL remain pending until an authorized human approves it

#### Scenario: Uncertain automatic acceptance

- **GIVEN** automatic acceptance is enabled
- **WHEN** supporting evidence or conflict eligibility cannot be established
- **THEN** the system SHALL leave the proposal for human review rather than automatically update accepted content

### Requirement: Authorization is enforced by server capabilities

The server SHALL distinguish proposal, review, accepted-edit, policy-management, and purge capabilities using trusted credentials. Agent credentials SHALL receive proposal-only authority for curated knowledge by default. Client-supplied actor labels SHALL NOT grant permissions. All server adapters SHALL enforce the same effective access and mutation policy.

#### Scenario: Agent attempts direct accepted edit

- **GIVEN** a credential has proposal authority but lacks accepted-edit authority
- **WHEN** it attempts an accepted curated-note edit through REST, MCP, append, restore, or another mutation path
- **THEN** the server SHALL deny that mutation

#### Scenario: Actor spoofing

- **WHEN** a caller changes an attribution header to name an approver
- **THEN** its granted capabilities SHALL remain unchanged

### Requirement: Policy inherits through folders with note overrides

Access and approval rules SHALL resolve from vault defaults and folder ancestors, using the nearest configured folder policy and explicit note overrides. Database membership SHALL NOT create a second policy hierarchy. Block-level policy overrides SHALL be reserved for future extension and SHALL NOT be implemented initially.

#### Scenario: Note policy override

- **GIVEN** a note inherits its nearest folder's approval policy
- **WHEN** an authorized policy manager sets a note override
- **THEN** subsequent eligibility checks SHALL use the effective overridden policy

#### Scenario: Moving between policy scopes

- **WHEN** a note moves to a folder with different effective rules
- **THEN** subsequent access and acceptance SHALL use the new rules and stale acceptance eligibility SHALL be invalidated

### Requirement: Independent blocks merge and changed blocks require review

Acceptance SHALL compare the touched block revisions under the note mutation lock. Changes to disjoint blocks SHALL be independently mergeable. A changed or ambiguously mapped target block SHALL require re-review. Conflicting proposals SHALL remain pending for authorized human resolution. A multi-block acceptance SHALL commit its operations together.

#### Scenario: Disjoint accepted changes

- **GIVEN** two proposals target different unchanged blocks
- **WHEN** one is accepted and increments the note version
- **THEN** the other SHALL remain eligible based on its unchanged target block rather than fail solely because the note version advanced

#### Scenario: Same-block change

- **WHEN** a proposal's target block changes after its base was recorded
- **THEN** prior approval SHALL be invalidated and acceptance SHALL require re-review

### Requirement: Authorized human saves create accepted history

Authorized humans SHALL be able to save curated notes directly. Such saves SHALL create accepted revisions and SHALL trigger re-review for pending proposals touching changed blocks. They SHALL preserve unrelated proposals against unchanged blocks.

#### Scenario: Direct save overlaps a proposal

- **WHEN** an authorized human directly edits a block with a pending proposal
- **THEN** a new accepted revision SHALL be recorded and that proposal SHALL require re-review

### Requirement: Accepted history remains until explicit purge

The system SHALL retain accepted revisions until an authorized user explicitly purges them. Restore SHALL create a new monotonic accepted revision. Deletion recovery, purge scope, and audit erasure semantics SHALL be defined explicitly. Accepted history SHALL remain coherent with the canonical document after interrupted mutations.

#### Scenario: Restoring prior knowledge

- **WHEN** an authorized user restores a retained accepted revision
- **THEN** the restored content SHALL become a new accepted revision without erasing intervening history

#### Scenario: Interrupted accepted mutation

- **WHEN** a mutation is interrupted between history preparation and document publication
- **THEN** recovery SHALL complete or safely reject it before serving content, without exposing uncommitted history as accepted knowledge

### Requirement: Normal recall excludes proposals and review records

Normal reads, search, embeddings, links, database views, and agent recall SHALL use accepted content only. Pending proposals, comments, and historical evidence SHALL be available through explicit authorized inspection operations. Acceptance SHALL update the ordinary content indexes and events.

#### Scenario: Searching a pending claim

- **GIVEN** a claim exists only in a pending proposal
- **WHEN** an agent performs normal search or recall
- **THEN** that claim SHALL NOT appear as accepted knowledge

#### Scenario: Explicit proposal inspection

- **WHEN** an authorized agent explicitly inspects proposals while reviewing, proposing, or gardening
- **THEN** it SHALL receive proposal state and evidence clearly distinguished from accepted content

### Requirement: Evidence archives remain optional and separate

Conversation evidence capture SHALL be separately enabled and SHALL have configurable retention independent of accepted knowledge history. Working observations MAY support proposals but SHALL NOT become accepted institutional knowledge solely through repetition or archiving. Future gardening operations SHALL use the same proposal and approval workflow.

#### Scenario: Archive disabled

- **GIVEN** optional evidence capture is disabled
- **WHEN** curated knowledge is reviewed and maintained
- **THEN** the curated workflow SHALL remain usable with other explicit supporting evidence
