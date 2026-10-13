## Purpose

Extract evidence-backed proposals from enabled sources implements a focused part of the merged curated knowledge contract while preserving existing ordinary note and memory workflows.

## ADDED Requirements

### Requirement: Conversation extraction triggers are configurable and opt-in

Conversation extraction SHALL require explicit capture and extraction enablement
for the selected vault and source scope. Its trigger SHALL support `session_end`,
`completed_turn`, and `both`, defaulting to `session_end` when extraction is enabled.
Trigger changes SHALL affect future observations without implicit historical replay.
Only durably acknowledged eligible source revisions SHALL create jobs.

#### Scenario: Asynchronous observation capture

- **WHEN** Hermes captures a turn or session observation
- **THEN** Hermes
callbacks SHALL enqueue bounded work without waiting for model extraction, and
subagent, cron, and flush provider contexts SHALL NOT emit automatic extraction
observations. A completed turn SHALL NOT be represented as a completed task.

#### Scenario: Default disabled configuration

- **WHEN** a conversation turn or session completes without explicit capture and extraction enablement
- **THEN** no background extraction job SHALL be created and existing ordinary memory behavior SHALL continue

#### Scenario: Session-end mode

- **WHEN** an enabled scope uses `session_end` and a completed turn is observed
- **THEN** extraction SHALL wait for an eligible session-boundary source observation

#### Scenario: Completed-turn mode

- **WHEN** an enabled scope uses `completed_turn` and an eligible turn source is durably acknowledged
- **THEN** a recoverable extraction job SHALL be scheduled without waiting for session end

#### Scenario: Both triggers enabled

- **WHEN** an enabled scope uses `both` and eligible turn and session-boundary sources are acknowledged
- **THEN** both observations SHALL be processed with shared durable coverage and duplicate suppression

#### Scenario: Trigger configuration changes

- **WHEN** the configured trigger changes
- **THEN** future observations SHALL follow the new trigger without automatically replaying old sources

#### Scenario: Restricted Hermes context

- **WHEN** a subagent, cron, or flush context completes a turn or session
- **THEN** its provider SHALL NOT submit automatic extraction observations

### Requirement: Extraction retains focused durable findings with evidence

The extractor SHALL treat sources as untrusted data and identify durable confirmed
facts, decisions with rationale, reusable procedures, and corrections. It SHALL
skip temporary task details, unsupported speculation, and unchanged duplicates.
Each candidate SHALL retain exact source revision and passage locators.

#### Scenario: Candidate comparison and review

- **WHEN** extraction produces candidate findings
- **THEN** candidates
SHALL be compared with readable accepted knowledge and authorized ongoing proposals.
Uncertain matches and contradictions SHALL remain explicit review diagnostics.
All extracted text SHALL require human review. An empty result SHALL complete
successfully without creating a proposal. Denied or unsupported proposal operations
SHALL NOT fall back to ordinary accepted writes.

#### Scenario: No durable finding

- **WHEN** a source contains only temporary details or unchanged knowledge
- **THEN** extraction SHALL complete without creating a proposal

#### Scenario: Sourced correction

- **WHEN** an eligible passage contradicts an existing accepted claim
- **THEN** the worker SHALL submit a sourced correction for human review with contradiction diagnostics and leave accepted text unchanged

### Requirement: Agents and extraction share a knowledge proposal workflow

The extractor SHALL follow read → compare → classify → propose, matching the
bundled plugin skill. It SHALL read immutable source passages, verify exact values
and quotations, and distinguish source assertions from derived inferences. It
SHALL compare findings by concepts, entity names, and aliases against readable
accepted knowledge and authorized ongoing proposals. Pending content SHALL NOT
establish a claim's truth. Generated answers SHALL NOT serve as independent evidence.

#### Scenario: Classified finding diagnostics

- **WHEN** extraction classifies a finding
- **THEN** each finding SHALL carry a reason and one or more dispositions: `new`, `update`, `disputed`, or `no_material`

The first three MAY combine; `no_material` SHALL be
exclusive. Jobs SHALL retain dispositions in authorized diagnostics, and retained
candidates SHALL include their dispositions and supporting source references.
New candidates SHALL be organized around durable concepts or entities rather than
conversation boundaries. Compatible additions SHALL target existing topics.
Corrections and disputes SHALL preserve prior claim lineage and explicit conflict
evidence, without automatic resolution or accepted writes. Related readable targets
requiring review SHALL be identified without silently changing their accepted content.
Source material SHALL remain unchanged.

#### Scenario: New concept

- **WHEN** a sourced durable finding has no matching accepted topic or ongoing proposal
- **THEN** it SHALL be classified as `new` and proposed around its concept with supporting evidence

#### Scenario: Compatible addition

- **WHEN** a sourced finding adds compatible knowledge to an existing topic
- **THEN** it SHALL be classified as `update` and proposed against that topic rather than creating a duplicate topic

#### Scenario: Conflicting sources

- **WHEN** a finding conflicts with an existing claim and available evidence does not resolve the disagreement
- **THEN** it SHALL be classified as `disputed`, retain both claims and their source references for human review, and leave accepted knowledge unchanged

#### Scenario: Existing pending candidate

- **WHEN** an authorized ongoing proposal already contains the unchanged finding
- **THEN** it SHALL be classified as `no_material` without a duplicate proposal or treating the pending claim as accepted truth

#### Scenario: Related claims affected

- **WHEN** new evidence affects claims in multiple readable notes
- **THEN** the candidate SHALL identify the related targets requiring review without silently rewriting accepted claims

### Requirement: Trigger overlap and extraction work are bounded

Jobs SHALL retain consumed source coordinates and candidate fingerprints within
their conversation, scope, and extractor generation. Session-end processing SHALL
NOT resubmit unchanged candidates already produced from completed turns. Updated
claims SHALL retain prior lineage. Explicit re-extraction SHALL use a distinct
generation.

#### Scenario: Bounded queued work

- **WHEN** source observations enter the extraction queue
- **THEN** input size, candidate count, model execution time, and retries SHALL
have configured bounds. Queue coalescing SHALL preserve uncovered source
coordinates. Authorized job inspection SHALL expose status and limit diagnostics
without leaking source text.

#### Scenario: Session end repeats a processed turn

- **WHEN** session-end input includes a passage already processed in completed-turn mode
- **THEN** unchanged candidates SHALL NOT create duplicate proposals and new context SHALL remain eligible for extraction

#### Scenario: Repeated observation delivery

- **WHEN** the same source observation is delivered again after a lost acknowledgement
- **THEN** its stable key SHALL recover the existing job and proposal identities

#### Scenario: Work exceeds a configured limit

- **WHEN** extraction exceeds an input, candidate, execution-time, or retry bound
- **THEN** progress and limit diagnostics SHALL remain inspectable without silently losing uncovered source passages

### Requirement: Jobs recover without duplicates

Jobs SHALL durably store leases, state, checkpoints and proposal identities before checkpoint advancement.

#### Scenario: Jobs recover without duplicates

- **WHEN** the worker crashes after persisting its proposal
- **THEN** lease recovery SHALL reuse that proposal without duplicate candidate groups

### Requirement: Extraction cannot publish knowledge

The worker SHALL hold source-read and proposal permissions only and preserve passage evidence.

#### Scenario: Extraction cannot publish knowledge

- **WHEN** an extracted claim is generated
- **THEN** it SHALL remain a proposal until independent policy-controlled acceptance

### Requirement: Revocation stops processing

Workers SHALL recheck access, source availability and extraction enablement before reads and submissions.

#### Scenario: Revocation stops processing

- **WHEN** extraction is disabled or source access revoked while running
- **THEN** further protected reads and new proposal submissions SHALL stop

### Requirement: Slice conforms to the merged contract

Implementation SHALL satisfy the applicable file, permission, review, retention, and compatibility requirements in `add-curated-knowledge/specs/curated-knowledge/spec.md`; this slice SHALL NOT weaken that contract. Feature activation SHALL remain gated by the integrated Hermes release verification.

#### Scenario: Foundation lands before integrated release

- **WHEN** this slice passes its focused checks before all dependent release checks pass
- **THEN** incomplete curated functionality SHALL remain disabled and existing ordinary workflows SHALL remain available

### Requirement: Model output and source citations are verified

The adapter SHALL reject malformed finding containers as `model_output`.
Classification SHALL use string dispositions and a separate reason; properties
and named relations SHALL be objects. Source citations SHALL match immutable
original text without normalization.

#### Scenario: Unique exact quote with inaccurate model offsets

- **WHEN** integer model offsets do not match a nonempty exact quote that occurs
  once within the current source chunk
- **THEN** the worker SHALL derive Unicode scalar offsets from that chunk and
  verify the immutable passage before proposing

#### Scenario: Repeated exact quote with valid explicit offsets

- **WHEN** an exact quote occurs more than once but supplied offsets identify an
  exact passage within the current chunk
- **THEN** the worker SHALL retain those verified offsets

#### Scenario: Missing or ambiguous quote cannot be recovered

- **WHEN** supplied offsets fail verification and the quote is absent or occurs
  more than once within the current chunk
- **THEN** extraction SHALL remain blocked without a proposal or accepted write

#### Scenario: No material requires no candidate payload

- **WHEN** a finding contains only `no_material` and a reason
- **THEN** the adapter SHALL accept that classification without candidate fields
