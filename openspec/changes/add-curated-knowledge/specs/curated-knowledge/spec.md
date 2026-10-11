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


### Requirement: Reusable types guide authors and enforce structure

The system SHALL support Person, Project, Claim, Decision, Procedure, and Evidence as initial reusable types for ordinary Markdown entries. Types SHALL remain independent of folders and database membership. Each versioned type SHALL expose descriptions, examples, suggested sections, and agent guidance alongside required properties, value types, enumerations, cardinality, and allowed relation target types. Untyped ordinary notes SHALL remain supported.

#### Scenario: Discovering a type before authoring

- **WHEN** a human or authorized agent inspects the Decision type
- **THEN** the system SHALL expose its authoring guidance and machine-readable constraints with the definition identity and version

#### Scenario: Reusing a type across views

- **WHEN** a Project entry moves folders or appears in another database view
- **THEN** its semantic type identity SHALL remain unchanged and applicable database constraints SHALL remain enforced

### Requirement: Custom types extend established schemas

The system SHALL allow custom namespaced types to extend accepted imported type definitions and add local guidance, properties, and compatible constraints. External term identities and source mappings SHALL be preserved. Inheritance SHALL resolve against pinned definition versions. Cycles and conflicting inherited constraints SHALL prevent activation. External vocabulary guidance SHALL NOT become mandatory without an explicit constraint.

#### Scenario: Extending an imported type

- **WHEN** an authorized user defines a custom Decision type extending an imported term with a required decision date
- **THEN** its effective definition SHALL preserve the parent term identity and include the local requirement

#### Scenario: Conflicting inheritance

- **WHEN** a proposed type introduces cyclic inheritance or incompatible constraints
- **THEN** activation SHALL fail with actionable diagnostics and accepted definitions SHALL remain unchanged

### Requirement: Ontologies can be adopted in bulk

The system SHALL initially bulk-adopt the complete supported vocabulary of a pinned published Schema.org release and support local types and constraints extending its terms. Schema.org adoption SHALL record an explicit release identifier, release artifact source, and immutable snapshot digest. It SHALL NOT use a moving latest or development endpoint as the accepted vocabulary source. The system SHALL retain the bulk-adoption contract for later user-selected ontologies. Adoption SHALL record its source, namespace, pinned version or immutable snapshot digest, and dependencies. Before activation, a preview SHALL identify imported terms, identity collisions, unresolved dependencies, and unsupported constructs. Unsupported semantics SHALL NOT be silently discarded. Activation SHALL require authorized review and an explicit disposition for unsupported constructs. Repeating adoption of the same snapshot SHALL be idempotent. Ontology upgrades SHALL require a separately reviewed version change.

#### Scenario: Adopting Schema.org rather than individual terms

- **WHEN** an authorized user adopts a pinned published Schema.org release after reviewing its preview
- **THEN** the supported type and property definitions SHALL become available together without manual adoption of each term
- **AND** repeating the adoption SHALL NOT create duplicate definitions

#### Scenario: Local constraints over imported vocabulary

- **GIVEN** a pinned Schema.org release has been adopted
- **WHEN** an authorized user defines a local type with required properties and named relation constraints
- **THEN** the effective definition SHALL retain imported term identities and enforce the explicit local constraints
- **AND** imported suggested properties SHALL NOT become required solely through bulk adoption

#### Scenario: Later vocabulary extensions

- **WHEN** the initial Schema.org vocabulary and local types are activated
- **THEN** PROV-O and SKOS adoption SHALL NOT be required for authoring, validation, evidence references, or accepted relation queries
- **AND** vocabulary namespaces and version identities SHALL permit their separate adoption in a later extension

#### Scenario: Unsupported ontology constructs

- **WHEN** an import contains unsupported constructs or unresolved dependencies
- **THEN** the preview SHALL identify them and activation SHALL remain blocked until their disposition is explicitly reviewed and dependencies are resolved
- **AND** the system SHALL NOT claim enforcement or inference for unsupported semantics

### Requirement: Acceptance validates typed knowledge

Drafts and proposals MAY remain structurally incomplete and SHALL expose validation diagnostics. Acceptance and authorized direct curated writes SHALL validate the complete resulting candidate entry against accepted, pinned type-definition versions after applying sets, unsets, replacements, and relation changes, before publication. Invalid mutations SHALL leave accepted knowledge unchanged. Structural validity SHALL NOT establish factual truth or bypass evidence and approval policy. Changes to applicable definitions SHALL invalidate affected pending acceptance eligibility.

#### Scenario: Incomplete typed proposal

- **WHEN** a proposed Decision omits a required property or supplies an invalid relation target
- **THEN** it SHALL remain inspectable with actionable diagnostics but SHALL NOT become accepted knowledge

#### Scenario: Removing a required property

- **GIVEN** an accepted Decision has a required rationale
- **WHEN** a mutation unsets the rationale or replaces its properties without that value
- **THEN** validation SHALL reject the complete candidate and preserve the accepted revision

#### Scenario: Removing a required relation

- **WHEN** a mutation removes the last supported_by relation from an accepted Claim
- **THEN** validation SHALL reject the resulting cardinality violation and preserve the accepted revision

#### Scenario: Valid evidence-backed proposal

- **WHEN** a typed entry satisfies its structural constraints
- **THEN** acceptance SHALL still require the effective evidence, authorization, and review checks

### Requirement: Named relations support accepted knowledge queries

The system SHALL support named relations between entities and knowledge objects using stable target identities. Titles and aliases SHALL remain display attributes. Prose wikilinks SHALL remain available. Required typed relations SHALL resolve to accepted targets or compatible entries accepted within the same atomic transaction, satisfying the declared target types. Prose, properties, and relations in a proposal SHALL be reviewable and accepted together. Normal queries and graph traversal SHALL use only accepted entries and relations and SHALL enforce effective read access for results, traversed targets, and evidence.

#### Scenario: Querying linked decisions

- **GIVEN** an accepted Decision affects an accepted Project and a pending proposal adds another such relation
- **WHEN** an authorized caller queries accepted decisions affecting the Project
- **THEN** only accepted relations and entries accessible to that caller SHALL contribute to the result

#### Scenario: Renaming a relation target

- **WHEN** an accepted Project is renamed
- **THEN** incoming named relations SHALL retain their target identity and display the updated title

#### Scenario: Breaking a required relation

- **WHEN** deletion or type migration would invalidate an enforced accepted relation
- **THEN** the mutation SHALL be rejected unless an authorized coherent migration resolves the affected relations

### Requirement: Relation integrity survives concurrent mutations

Relation acceptance, target deletion, and target type migration SHALL serialize integrity checks and publication across affected identities or provide equivalent transactional guarantees. No successful interleaving SHALL leave an accepted relation dangling or incompatible with its declared target type. Cross-document migrations SHALL publish coherently and recover before serving queries.

#### Scenario: Concurrent relation acceptance and target deletion

- **WHEN** acceptance of an incoming relation races with deletion of its target
- **THEN** both operations SHALL NOT succeed leaving a broken accepted relation
- **AND** the rejected operation SHALL leave its accepted revisions unchanged

#### Scenario: Concurrent relation acceptance and target migration

- **WHEN** an incoming relation is accepted concurrently with a target migration to an incompatible type
- **THEN** serialization or transaction validation SHALL reject one operation unless a coherent migration preserves the relation constraints

### Requirement: Type evolution preserves accepted knowledge

Type definitions and ontology adoption records SHALL follow curated review, authorization, provenance, and retained-history rules. An upgrade SHALL preview affected entries and validation failures. Accepted entries SHALL retain their pinned definition versions until an explicit reviewed migration succeeds. Failed imports, upgrades, or migrations SHALL NOT silently reinterpret existing accepted entries. Derived query indexes SHALL be rebuildable from accepted data and pinned definitions.

#### Scenario: Adding a required property

- **WHEN** a proposed type version adds a property missing from existing accepted entries
- **THEN** the preview SHALL identify those entries and they SHALL remain on their prior definition version until a reviewed migration succeeds

#### Scenario: Agent proposes a type change

- **WHEN** an agent with proposal-only authority submits a type definition or ontology upgrade
- **THEN** it SHALL remain pending under the effective review policy and SHALL NOT directly alter accepted validation or query behavior


### Requirement: Sources remain distinct from curated knowledge

The system SHALL record source, knowledge, and type-definition roles explicitly rather than infer them from folders. Source ingestion SHALL preserve original material and create immutable revisions when it changes. Ingestion SHALL NOT promote source statements into accepted knowledge. Default curated recall SHALL exclude raw source and type-definition documents. Authorized callers SHALL explicitly inspect sources to investigate or support proposals, independently of optional conversation archive enablement. Existing effective access and approval policies SHALL continue to apply after document moves.

#### Scenario: Importing a source

- **WHEN** an authorized caller imports a source document
- **THEN** its statements SHALL NOT appear in default curated recall until separately proposed and accepted as knowledge
- **AND** the original source revision SHALL remain available through authorized source inspection

#### Scenario: Moving a source document

- **WHEN** a source moves into a folder containing curated knowledge
- **THEN** its explicit source role SHALL remain unchanged and access SHALL use the destination's effective policy

### Requirement: Evidence pins original source revisions

Accepted Evidence SHALL reference a stable source identity, an immutable revision identifier, and a passage locator or an explicit whole-document locator. Acceptance SHALL verify that the referenced revision and locator resolve under the caller's effective access. Later source changes SHALL NOT redirect existing evidence to newer material. Referenced revisions SHALL remain resolvable until explicit authorized purge. Purge SHALL mark affected evidence references unavailable without silently changing their targets. Evidence acceptance SHALL NOT establish the truth of a supported claim.

#### Scenario: Updating a cited source

- **WHEN** a source receives a new revision after Evidence citing an earlier passage is accepted
- **THEN** the Evidence SHALL continue to resolve to the cited revision and passage

#### Scenario: Purging cited material

- **WHEN** an authorized purge removes a cited source revision
- **THEN** explicit evidence inspection SHALL report the unavailable reference and SHALL NOT return another revision as its replacement

### Requirement: Type definitions are canonical filesystem documents

Local and imported type definitions SHALL be canonical Markdown documents with structured metadata in the vault filesystem. Filesystem adoption manifests SHALL record imported definitions and their release snapshot. Documents and retained snapshots SHALL preserve identities, pinned versions and parents, properties, relation constraints, guidance, and source mappings. Validation and query indexes SHALL be rebuildable from accepted filesystem documents and retained snapshots without a database-only registry or remote refetch. Externally edited files SHALL enter validation and review as candidates before activation. Invalid or unapproved candidates SHALL NOT replace accepted definitions. Portable export SHALL include referenced pinned definition snapshots and adoption manifests.

#### Scenario: Rebuilding type indexes

- **GIVEN** imported and local types have accepted filesystem documents and retained snapshots
- **WHEN** derived indexes are removed and rebuilt without network access
- **THEN** validation and queries SHALL retain the same pinned definitions and constraints

#### Scenario: External type edit followed by restart

- **WHEN** an external edit changes a type document without acceptance and the server restarts
- **THEN** the edit SHALL remain a candidate and the prior accepted definition SHALL remain active

### Requirement: Initial local types have concrete minimum constraints

Every initial local type SHALL require the existing non-empty note title and a pinned type assignment. Person SHALL require a non-empty display_name. Project SHALL require a non-empty summary. Claim SHALL require a non-empty statement and at least one supported_by relation to Evidence. Decision SHALL require a non-empty rationale, one decision_date using the existing date encoding, a status from proposed, accepted, or superseded, and at least one affects relation to Project. Decision status SHALL remain distinct from document review state. Procedure SHALL require at least one non-empty ordered step and at least one maintained_by relation to Person. Evidence SHALL require one source identity, one immutable source revision identifier, and one non-empty passage or whole-document locator.

The initial types SHALL permit zero or more Project maintained_by Person, Decision supported_by Evidence, Decision supersedes Decision, and Procedure supported_by Evidence relations. Every supplied named relation SHALL resolve to an accepted compatible knowledge target or one accepted within the same atomic transaction, except Evidence source references which SHALL resolve to retained source revisions. These local constraints SHALL NOT make unconstrained imported suggestions mandatory.

#### Scenario: Validating all starting types

- **WHEN** an author submits a candidate for any of the six starting types missing its required value or violating its declared relation cardinality or target type
- **THEN** acceptance SHALL fail with a diagnostic identifying the type, field, and violated constraint

#### Scenario: Domain decision status differs from review state

- **WHEN** an authorized reviewer accepts a structurally valid Decision whose domain status is proposed
- **THEN** the document SHALL be accepted knowledge while its decision status SHALL remain proposed


### Requirement: Files use explicit versioned metadata and writers

Source descriptors, knowledge entries, type definitions, vocabulary terms, and ontology adoption manifests SHALL use UTF-8 Markdown with YAML frontmatter and the server-managed `knowledge` object described in the design's file format contract. `knowledge` SHALL be reserved from free-form database property writes. Its format_version SHALL be 1 initially. Role and stable references SHALL determine meaning independently of path. Unknown format versions SHALL prevent activation with diagnostics. Primitive knowledge properties SHALL preserve existing frontmatter encoding. Typed knowledge relations SHALL use stable note identities without redefining existing title-based database relations.

The importer SHALL generate imported definition and manifest candidates. Humans and authorized agents SHALL author local type and knowledge candidates. Ingestion adapters SHALL submit source material. The server SHALL be the accepted publisher, enforcing the applicable ingestion or curated review policy. External file edits SHALL remain candidates. Trusted identity, source hashes, and revision IDs SHALL be server-derived. Proposal and extraction job records SHALL remain durable sidecar data.

#### Scenario: Reading a file-backed type

- **WHEN** an authorized author reads a local type document
- **THEN** its structured metadata SHALL expose identity, version, parents, properties, relations, and guidance using the documented encoding

#### Scenario: Unsupported file version

- **WHEN** an imported or externally edited document declares an unknown knowledge format version
- **THEN** the server SHALL reject activation with diagnostics without replacing accepted definitions

### Requirement: Source files retain original material and precise locators

Each source descriptor SHALL record stable source identity, immutable revision, media type, digest, vault-local blob reference, adapter label, and capture time. The retained revision SHALL preserve original bytes. Evidence locators SHALL encode either whole_document or text_range with zero-based Unicode scalar offsets and an exclusive end in the referenced UTF-8 text revision. Non-text revisions SHALL initially support whole-document locators. Source blobs SHALL NOT enter default curated recall. Original source frontmatter SHALL NOT be interpreted as trusted knowledge metadata.

#### Scenario: Capturing source Markdown with frontmatter

- **WHEN** an adapter submits Markdown containing a claimed role or actor in frontmatter
- **THEN** the server SHALL preserve those bytes as source material and SHALL derive descriptor identity and access from authenticated ingestion

#### Scenario: Citing a retained passage

- **WHEN** Evidence supplies a text_range locator outside its retained text revision
- **THEN** validation SHALL reject acceptance rather than silently cite different text

### Requirement: Adapter capture is opt-in and idempotent

Automatic capture SHALL default to disabled and require explicit authorized enablement per scope and adapter. Explicit source import SHALL remain separate. Hermes and other adapters SHALL use one source ingestion contract carrying vault, adapter, stable event ID, payload, media type, observation time, and requested scope. The server SHALL derive principal and allowed scope from credentials. Repeat delivery of an event with identical payload SHALL return the same revision. Reusing that event ID with different payload SHALL fail as a conflict. Existing ordinary memory writes SHALL NOT silently enable capture or become curated knowledge.

#### Scenario: Capture disabled

- **WHEN** a memory adapter attempts automatic source capture without opt-in
- **THEN** no source SHALL be captured and no extraction job SHALL be created

#### Scenario: Retried adapter delivery

- **WHEN** Hermes or another adapter retries the same authorized event and payload
- **THEN** ingestion SHALL return the original source revision without duplicating material

### Requirement: Background extraction has proposal-only authority

A server background worker SHALL extract typed knowledge and Evidence proposals from eligible retained source revisions through an adapter-neutral workflow. Extraction SHALL require explicit scope enablement. Its credential SHALL have only necessary source-read and proposal permissions, never review, accepted-edit, policy-management, or purge authority. Sources SHALL be treated as untrusted input. Every extracted assertion SHALL retain source revision and locator references. Uncertain entity matches and contradictions SHALL be exposed for review. Automatic acceptance SHALL remain a separate policy-controlled server operation.

#### Scenario: Extracting a claim

- **WHEN** an enabled worker extracts a Claim from an authorized source passage
- **THEN** it SHALL submit a typed proposal with Evidence and source lineage, leaving accepted knowledge unchanged until eligible acceptance

#### Scenario: Introducing Evidence and Claim together

- **WHEN** a reviewed proposal introduces new Evidence and a Claim referencing it
- **THEN** validation SHALL evaluate the complete candidate set and acceptance SHALL publish both atomically
- **AND** no accepted intermediate state SHALL reference pending Evidence

#### Scenario: Worker attempts acceptance

- **WHEN** the extraction credential attempts to approve or directly publish knowledge
- **THEN** the server SHALL deny the operation regardless of source content or adapter label

### Requirement: Extraction jobs survive retries and respect revocation

The scheduler SHALL durably track jobs, leases, checkpoints, attempts, proposal identities, and queued, running, retry_wait, blocked, completed, or cancelled state. Jobs SHALL pin source revision, originating principal and scope, extractor configuration, and type versions. Stable job and proposal keys SHALL prevent duplicate jobs or proposals during delivery retries and crash recovery. Transient failures SHALL use bounded backoff. Permanent failures SHALL remain inspectable. Authorized health inspection SHALL expose job status without leaking source text.

The worker SHALL recheck effective authorization, extraction eligibility, source availability, and type freshness before reads and submissions. Disabling capture SHALL stop new automatic ingestion. Disabling extraction SHALL cancel queued jobs and prevent running jobs from submitting new proposals. Revoked access, excluded sources, expiration, and purge SHALL block affected work. Intentional re-extraction SHALL retain lineage and use a distinct configuration or explicit generation.

#### Scenario: Crash after proposal persistence

- **WHEN** a worker crashes after persisting a proposal but before advancing its checkpoint
- **THEN** lease recovery and retry SHALL reuse the existing proposal identity without creating a duplicate

#### Scenario: Disabling extraction during processing

- **WHEN** extraction is disabled or source access is revoked while a job runs
- **THEN** the worker SHALL stop further protected reads and SHALL NOT submit new proposals under the stale eligibility


### Requirement: Agent tools share one knowledge contract

REST, MCP, Hermes, other adapters, and the extraction worker SHALL expose or invoke the same type discovery, accepted knowledge query, source inspection, candidate validation, and proposal service semantics defined in the design's shared agent contract. Adapters SHALL NOT bypass authorization, bounds, validation, or idempotency rules. Each call SHALL identify its vault and use authenticated principal identity. Tool descriptions SHALL expose input shapes, outputs, filters, limits, evidence encoding, and permission requirements.

#### Scenario: Discovering accepted types

- **WHEN** an authorized agent lists types and reads a pinned type definition
- **THEN** it SHALL receive accepted identities, versions, guidance, and effective inherited constraints without pending definition content

#### Scenario: Equivalent clients

- **WHEN** Hermes and the extraction worker submit equivalent authorized candidate groups through their adapters
- **THEN** the service SHALL apply the same validation and proposal semantics without granting either client acceptance authority

### Requirement: Accepted queries are bounded and revision-aware

Knowledge queries SHALL support type, property, and named relation filters, sorting, and opaque pagination cursors as defined in the design. Default page size SHALL be 50 and maximum 200. Optional outgoing traversal SHALL be limited to depth 2 and 200 nodes and SHALL report truncation. Results SHALL include stable entry IDs, accepted revisions, and pinned type versions. Only accessible accepted entries and relations SHALL contribute to results, counts, or paths. Cursors SHALL bind arguments, vault, and an accepted index revision. Unsupported continuation SHALL return cursor_stale. Access SHALL be rechecked on every page and node.

#### Scenario: Querying with a hidden intermediate node

- **WHEN** an accepted relation path crosses a node the caller cannot read
- **THEN** traversal SHALL NOT reveal the node, its onward path, or a count derived from it

#### Scenario: Index changes during pagination

- **WHEN** an agent continues a query whose cursor revision can no longer be served consistently
- **THEN** the service SHALL return cursor_stale rather than silently mix incompatible pages

### Requirement: Explicit source inspection and validation respect access

Source inspection SHALL require source-read authority and an explicit source identity and immutable revision. It SHALL return a bounded excerpt or scoped non-text attachment reference without enabling source inclusion in default recall. Candidate validation SHALL require proposal authority and access to referenced knowledge, types, and sources. It SHALL evaluate the complete candidate group without writing documents, proposals, or source material. Diagnostics SHALL identify operations, fields, and violated constraints. Validation SHALL NOT authorize later acceptance. Inaccessible references SHALL be indistinguishable from absent references in public responses.

#### Scenario: Validating without publishing

- **WHEN** an authorized agent validates a group containing new Evidence and a Claim referring to it
- **THEN** the service SHALL resolve intra-group references and return diagnostics without persisting the group

#### Scenario: Access revoked after validation

- **WHEN** access to supporting material is revoked after successful validation
- **THEN** subsequent proposal submission or acceptance SHALL recheck access and SHALL NOT rely on the earlier validation result

### Requirement: Agent proposals are idempotent atomic candidate groups

Agents SHALL submit structured create and update operations alongside Markdown, property sets and unsets, named relation changes, pinned types, expected accepted bases, and revision-specific evidence. New entries SHALL use unique local references for intra-group targets. The server SHALL serialize document files. Malformed operations, unauthorized writes, or inaccessible references SHALL fail before persistence. Structurally incomplete proposals MAY persist with diagnostics but SHALL NOT be accepted until valid. Updates SHALL check applicable entry or block base revisions. Reviewed multi-entry acceptance SHALL publish the complete valid group atomically or none, including across crash recovery.

Idempotency keys SHALL be scoped to vault, authenticated principal, and operation. Identical key and canonical payload SHALL return the original persisted result; changed payload SHALL return idempotency_conflict. Proposal persistence and idempotency records SHALL share a recoverable transaction. Purge SHALL retain a non-content consumed-key record to prevent accidental recreation through retry. Proposal inspection SHALL expose authorized state, diagnostics, and review activity. Amendments SHALL require the expected proposal revision, retain earlier versions, and invalidate approvals for changed content.

#### Scenario: Retrying after a lost proposal response

- **WHEN** an adapter retries an identical proposal after the original durable write's response is lost
- **THEN** it SHALL receive the original proposal ID and revision without duplicate proposals or accepted writes

#### Scenario: Reusing a key with changed content

- **WHEN** an agent reuses a consumed idempotency key with a different candidate payload
- **THEN** the service SHALL return idempotency_conflict and preserve the original proposal

#### Scenario: Retrying a purged proposal

- **WHEN** an adapter retries a key whose original proposal was explicitly purged
- **THEN** the service SHALL report that the key is consumed without restoring purged content or creating another proposal

#### Scenario: Partial publication fails

- **WHEN** acceptance of an Evidence and Claim group is interrupted during publication
- **THEN** recovery SHALL complete or reject the group before serving queries and SHALL NOT expose only part of the accepted group

#### Scenario: Concurrent proposal amendment

- **WHEN** an agent amends a proposal using an outdated expected proposal revision
- **THEN** the service SHALL return version_conflict and preserve the current proposal and review history


### Requirement: Hermes compatibility gates the initial release

The initial curated knowledge release SHALL include a working Hermes adapter for the shared agent contract. Release readiness SHALL require passing contract tests and isolated live-server end-to-end verification for the supported server and plugin pair. Completed planning tasks SHALL NOT count as passing runtime verification.

With capture and extraction disabled, the plugin SHALL preserve existing ordinary memory writes, recall, configured identity destinations, scoped authorization, durable retries, and health reporting. Read-only configurations SHALL retain recall without capture or proposal writes. Opt-in capture SHALL add source ingestion without silently replacing existing ordinary memory delivery. Accepted-only curated recall SHALL remain distinct from existing ordinary memory recall.

#### Scenario: Existing memory with new features disabled

- **WHEN** Hermes runs against the supported server with capture and extraction disabled
- **THEN** existing memory writes, scoped recall, identity destinations, durable retry recovery, and health reporting SHALL continue to work without source capture or extraction jobs

#### Scenario: Read-only Hermes configuration

- **WHEN** Hermes uses a credential permitting recall but no writes
- **THEN** recall SHALL remain available and automatic capture and proposal submission SHALL NOT occur

### Requirement: Hermes exposes tools with capability-aware compatibility

Hermes SHALL expose type discovery, accepted knowledge queries, source inspection, candidate validation, and proposal submission, inspection, and amendment through the shared contract. The server SHALL publish its knowledge contract version and supported operations. Hermes SHALL discover capabilities before using new operations and report explicit unsupported-capability diagnostics for older or partially supporting servers. Existing memory operations SHALL remain usable when knowledge tools are unsupported. Denied or unsupported proposal operations SHALL NOT fall back to ordinary accepted writes. Advertised capabilities SHALL NOT substitute for credential permissions.

#### Scenario: Server lacks knowledge tools

- **WHEN** Hermes connects to a server without the knowledge contract
- **THEN** new knowledge operations SHALL report unsupported-capability diagnostics and existing ordinary memory operations SHALL remain usable

#### Scenario: Proposal permission denied

- **WHEN** Hermes attempts a supported proposal operation without proposal authority
- **THEN** it SHALL report denial without retrying the candidate through a direct note write

### Requirement: Isolated Hermes verification proves the complete flow

Release verification SHALL exercise the real plugin's memory-provider interface and registered tools against a real throwaway server. Ports, vault, datastore, Hermes home, outbox, credentials, and processes SHALL be isolated from user and production state. Deterministic extraction fixtures SHALL make workflow verification repeatable. Verification SHALL cover existing feature-disabled behavior, opt-in observation capture, Evidence and knowledge proposal creation, accepted-only visibility, separately authorized acceptance, durable retry recovery, and capability and permission failures. Evidence SHALL record server, plugin, Hermes runtime, and contract versions and check results. Verification SHALL clean up its resources. Inability to establish isolation SHALL leave the gate unverified.

#### Scenario: Capture through accepted recall

- **WHEN** isolated Hermes captures an authorized observation and the background worker extracts its Evidence and Claim proposal
- **THEN** the source and pending proposal SHALL be inspectable but absent from accepted knowledge queries and curated recall
- **AND** after a separately authorized test reviewer accepts the group, Hermes SHALL retrieve the accepted Claim and its evidence references through the shared tools

#### Scenario: Recovering delivery and submission retries

- **WHEN** isolated verification injects a lost response or restart during source delivery and proposal submission
- **THEN** recovery SHALL retain stable source and proposal identities without duplicates and existing ordinary memory retry behavior SHALL remain functional
