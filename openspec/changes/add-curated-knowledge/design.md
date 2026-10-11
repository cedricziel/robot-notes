## Context

Accepted content is canonical Markdown. `Storage` serializes note writes and replaces files atomically; `NoteWriteService` coordinates indexes and broadcasts. Flutter uses a raw Markdown editor and whole-note version checks. REST and MCP share writes but do not yet share a note-policy authorization layer. `X-Actor` is attribution, not an authenticated identity.

## Agreed product contract

Institutional knowledge is curated and always available as accepted knowledge. Ordinary notes can be designated curated knowledge. Humans and agents can contribute, but agent changes use proposals. Authorized humans can save directly with history. Default institutional policy requires human approval. Folders and individual notes may enable automatic acceptance for evidence-backed, non-conflicting updates. Conflicts require human resolution.

Comments and review attach to stable blocks. A proposal can affect several blocks. Changes to disjoint blocks merge independently; changes to a touched block invalidate its prior review. Access and approval rules inherit from the nearest configured folder and can be overridden at note level. Accepted history remains until explicit authorized purge. The evidence archive is separately enabled and has independent retention.

## Accepted document and review storage

Keep the existing Markdown file as the accepted document. Store proposals, comments, identities, and history outside ordinary content and its indexes. Only acceptance or an authorized direct save changes searchable content. Historical and pending data have explicit inspection endpoints.

Use a durable review/history store per vault, separate from disposable search indexes. Accepted document, revision, block map, and mutation journal form one recoverable operation. Replay interrupted operations before rebuilding indexes or serving content. An uncommitted candidate snapshot must not appear as an accepted revision.

Restore creates a new accepted revision, with a source-revision reference; it does not rewind version counters or erase intervening decisions. Deletion retains authorized recovery information. Purge explicitly removes retained content and associated history according to documented erasure semantics. Purging a live note's old history does not silently disable future version capture.

## Block identity while preserving Markdown

Parse supported top-level Markdown blocks while retaining exact source text. Treat lists, tables, fenced code, and custom embedded constructs conservatively. Persist opaque block IDs and per-block revisions in sidecar revision metadata; content hashes check freshness but do not identify blocks.

Keep IDs for unchanged or unambiguously moved blocks. Splits, merges, duplicate text, or arbitrary external rewrites may make correspondence ambiguous. Mark affected proposals and anchors for re-review rather than guessing. IDs are guaranteed through supported server operations, not through arbitrary export/import that omits sidecar metadata. A future portable identity format can add markers without changing review semantics.

Whole-note human saves continue to use the loaded note version and preserve text exactly. The server derives affected blocks against that accepted base. Explicit proposal acceptance checks touched block revisions under the same note lock and may succeed despite unrelated newer note revisions.

## Proposal and comment contract

A proposal records author principal, base accepted revision, touched block IDs and revisions, proposed operations, evidence references, and revisioned review activity. States are pending, changes requested, needs re-review, conflicted, accepted, and denied. Amendments retain earlier proposal versions and invalidate approvals for changed content.

Comments attach to block identity and a revision. They remain inspectable when a block changes or disappears; the interface identifies stale or orphaned anchors. An approval for a multi-block proposal commits its operations together. Partial approval requires a separately reviewable proposal amendment or split, not a silent partial commit.

The default normal note view is accepted content. Pending changes can be displayed as suggestions in explicit review mode, and agents can inspect proposals when reviewing, proposing, or gardening. Denied and superseded proposals remain audit history until authorized purge.

## Authorization and effective policy

Use server-issued credential identity and explicit permissions for proposal submission, review decisions, accepted-content editing, policy management, and purge. Agent credentials default to proposal authority. Human approval authority is explicitly provisioned; OAuth client names and actor headers cannot claim it. The shared operator key remains administrative and should not be distributed as an agent identity.

Resolve policy through vault defaults, ancestor folders, the nearest configured folder, and note overrides. The exact policy schema must define inheritance and intentional overrides, with no implicit permission escalation. Moving a note recalculates effective policy and invalidates acceptance eligibility when relevant rules change. Database membership does not add another policy hierarchy.

Apply effective read access to current notes, lists, search snippets, links, database query rows, files, history, proposal evidence, and WebSocket events. Apply mutation permissions centrally in the write/review services so REST, MCP, append, property edits, move, restore, and other paths cannot bypass policy. Authorized direct saves create history and invalidate overlapping pending proposals.

Reserve a future block-policy resolution layer, but implement no block-level access or approval overrides initially.

## Automatic acceptance

Automatic acceptance requires explicit effective policy, an authorized proposer, resolvable supporting evidence, unchanged target blocks, and the absence of a conflict established by the configured eligibility rules. Evidence existence alone does not establish truth. Unknown eligibility, stale evidence, policy changes, or a detected conflict leave the proposal pending or conflicted for human review.

Separate stale block checks from semantic conflicts: two disjoint blocks can still make contradictory claims. The initial implementation must define the operations it can establish as eligible and fail conservatively outside them. It must not claim universal semantic conflict detection. Record which policy and checks authorized an automatic acceptance so a human can review and reverse it.

## Memory stages

Accepted curated knowledge is the default recall source. Working observations can become proposals with evidence; they do not become institutional knowledge merely through repetition. Optional conversation evidence capture supports provenance and recovery but is distinct from curated knowledge. A later gardening agent submits consolidation or retirement proposals through the same permissions and review contract.

## Sources and curated knowledge

Represent source material, curated knowledge, and type definitions as distinct document roles in explicit metadata. Folders provide a convenient layout but do not determine the role. Existing folder access and approval policies still apply after moves. Imported documents, transcripts, and observations are sources. Person, Project, Claim, Decision, and Procedure entries are curated knowledge. Evidence is a curated reference to a specific source identity, revision, and passage or whole-document locator.

Source ingestion preserves the original material and records new immutable revisions when it changes. Ingestion does not promote source statements into accepted knowledge. Agents explicitly inspect authorized sources to investigate or prepare evidence-backed proposals. Default curated recall excludes raw sources and type definitions, while exposing accepted knowledge and its authorized evidence references. Source inspection remains available without enabling the optional conversation archive. A source revision cited by accepted Evidence remains resolvable until explicit authorized purge; purge marks references unavailable without redirecting them to newer content.

## Filesystem-backed type documents

Store local and imported type definitions as canonical Markdown documents with structured metadata in the vault filesystem. Ontology adoption manifests also live in the filesystem and identify the release snapshot and imported definitions. Preserve stable namespaced identities, pinned parent versions, properties, relations, constraints, examples, and authoring guidance in these documents. Accepted versions and retained history must be sufficient to rebuild validation and query indexes without a database-only schema registry or refetching remote definitions.

Treat externally edited type files as candidate revisions, not accepted definitions. Validate and review candidates through the curated workflow before activation. Malformed or unapproved external edits leave the prior accepted definition active, including across restart and index rebuild. Version history and the mutation journal retain the accepted snapshots needed for recovery. Reading or exporting current files alone does not preserve older pinned versions; portable export includes the referenced definition snapshots and adoption manifest.

## File formats and artifact writers

Use UTF-8 Markdown with YAML frontmatter for source descriptors, knowledge entries, local and imported type definitions, and adoption manifests. Add one server-managed `knowledge` frontmatter object, reserved from free-form database properties, without reusing the existing `type` discriminator. Its `format_version: 1` identifies this contract. Existing note identity and title fields retain their existing encoding. The examples omit server-managed ordinary note metadata for readability. Stable identities, not paths, resolve references.

Default paths are `types/schema.org/<release>/<term>.md`, `types/local/<name>.md`, `types/adoptions/<adoption-id>.md`, `sources/<source-id>.md`, and `knowledge/<note-id>.md`. Paths are conventions within the selected vault and may change without changing roles or identities. Source revision blobs and original attachments live in the retained source store, outside ordinary recall indexes. Review records, proposals, jobs, and mutation journals remain in durable sidecar stores, not accepted document prose.

A local type document uses the following shape. Property constraints use `value_type`, `required`, optional `enum`, and list `min_items` or `max_items`. Relation constraints use `target_types`, `min_items`, and optional `max_items`. Supported `value_type` values are text, number, boolean, date, and list; lists declare `items` with a primitive value_type. Required text is non-empty. Procedure steps use an ordered list with text items and min_items of one. Parent and target type references contain `id` and `version`.

```yaml
knowledge:
  format_version: 1
  role: type_definition
  definition:
    id: urn:robot-notes:type:Claim
    version: 1
    extends:
      - id: https://schema.org/Claim
        version: schema-release-id
    properties:
      statement: {value_type: text, required: true}
    relations:
      supported_by:
        target_types: [{id: 'urn:robot-notes:type:Evidence', version: 1}]
        min_items: 1
    guidance:
      sections: [Statement, Evidence]
      examples: ['State one claim and cite its supporting passage.']
      agent_instructions: 'Propose claims with revision-specific evidence.'
```

Imported type documents use the same definition shape and add `origin: {adoption_id, term_uri}`. Imported property terms use `role: vocabulary_term` with `term: {id, kind: property, version, origin, definition}`. Preserve original vocabulary semantics in `definition`; compile only explicitly supported constructs into enforced constraints. Adoption manifests use `role: ontology_adoption` and `adoption: {id, namespace, release, artifact_source, sha256, definitions, dependencies, unsupported_dispositions}`. `definitions` lists stable term identities and pinned versions. Keep the original release artifact in retained storage and identify it in the manifest.

Knowledge entries use the following shape. Primitive properties remain ordinary top-level frontmatter for compatibility with database views. Named relation values are lists of stable note IDs, not title-based database relation strings. Expose these through typed knowledge APIs and compatible derived views without changing existing database relation encodings.

```yaml
statement: Agent credentials require scoped permissions.
knowledge:
  format_version: 1
  role: knowledge
  types: [{id: 'urn:robot-notes:type:Claim', version: 1}]
  relations:
    supported_by: [evidence-note-id]
```

Source descriptors use `knowledge: {format_version: 1, role: source, source: {id, revision, media_type, sha256, blob_ref, adapter, captured_at}}`. `blob_ref` resolves within the selected vault's retained store, never to an arbitrary filesystem path. Retain original bytes, including original Markdown frontmatter, in the revision blob. Descriptor prose is a human-readable description, not a replacement for original material. Evidence entries use `role: knowledge`, the Evidence type assignment, and `evidence: {source_id, source_revision, locator}` inside `knowledge`. Locators are either `{kind: whole_document}` or `{kind: text_range, start, end}` with zero-based Unicode scalar offsets and an exclusive end in the retained UTF-8 text revision. Non-text material initially uses whole-document locators. Evidence's required source fields are read from this structured reference, not duplicate editable properties.

| Artifact | Candidate writer | Accepted publisher |
|---|---|---|
| Imported definitions and adoption manifest | Server importer invoked by an authorized caller | Server after adoption review |
| Local type document | Human editor or proposal-authorized agent | Server after validation and applicable review, or authorized direct save |
| Source descriptor and original revision | Ingestion adapter submits material and an idempotency key | Server ingestion service after capture policy and access checks |
| Knowledge and Evidence entry | Human editor, agent, or extraction worker | Server after validation and applicable review, or authorized direct save |
| Proposals and extraction jobs | Proposal service and background scheduler | Server durable sidecar store; never published as accepted notes |
| Derived indexes | Server indexer | Rebuilt from accepted documents and retained snapshots |

External file edits are candidate inputs, not another accepted publication authority. The server derives trusted actor identity from credentials, hashes from received bytes, and revision IDs from retained writes. Adapter labels are descriptive, not authorization claims.

## Adapter-neutral background extraction

Capture is off by default and explicitly enabled per authorized scope and adapter. Explicit source imports remain available separately. Hermes and future adapters submit observations through one ingestion contract: vault, adapter name, stable event ID, source payload and media type, observation time, and requested scope. The server derives the trusted principal and permitted scope from credentials, rejects excess scope, and returns the same source revision for repeated delivery of the same event and payload. A repeated event ID with different payload is a conflict. Hermes durable delivery retries use this contract; existing ordinary memory writes are not silently converted into captured sources or curated knowledge.

A durable server scheduler enqueues eligible retained source revisions only when extraction is enabled for their scope. Jobs record source revision, trusted originating principal and scope, extractor configuration version, pinned type versions, checkpoint, attempt count, and state: queued, running, retry_wait, blocked, completed, or cancelled. Claim leases and recover expired leases after crashes. Use a stable job key over vault, source revision, extraction configuration, and type versions. Store candidate proposal IDs before advancing checkpoints so retry and crash recovery cannot duplicate published proposals. Intentional re-extraction uses a new configuration or explicit generation and preserves earlier lineage.

The worker explicitly reads authorized sources and accepted type definitions, resolves existing entities conservatively, and constructs Evidence and typed knowledge proposals with passage references. Unknown matches and contradictions remain review diagnostics. Multi-document proposals can introduce Evidence and dependent Claims together. Validate references against the complete candidate set, then publish all accepted documents atomically if reviewed acceptance succeeds. Required targets may therefore be accepted in the same transaction. No intermediate accepted Claim may reference pending Evidence.

The extraction credential has source-read and proposal authority in its permitted scope, never review, direct accepted-edit, policy-management, or purge authority. The worker cannot grant itself automatic acceptance. Any automatic acceptance is a separate server policy decision using the existing checks. Recheck effective authorization, capture and extraction eligibility, source availability, and type freshness before each read and proposal submission. Sources are untrusted data, not instructions granting tool access or changing policy.

Disabling capture stops new automatic ingestion. Disabling extraction cancels queued jobs and prevents running jobs from submitting new proposals. Revocation, exclusion, expiration, or purge blocks jobs requiring unavailable inputs. Transient failures use bounded backoff; permanent failures remain inspectable without endless retry. Health exposes queue state and actionable failures to authorized users without leaking source text. Consolidation and retirement gardening remain later extensions.

## Ontologies, reusable types, and linked knowledge

Support entities and knowledge objects as ordinary Markdown notes with stable identities. Start with Person and Project for entities, and Claim, Decision, Procedure, and Evidence for knowledge objects. These are reusable semantic types, independent of folder location and database membership. Existing database property schemas remain compatible views and constraints, not the identity of a knowledge type. Preserve the existing reserved frontmatter keys when choosing the type-assignment representation.

A versioned type definition contains a stable namespaced identity, description, parent type references, properties, relation definitions, and authoring guidance. Guidance includes examples, suggested sections, and instructions available to humans and agents. Enforced constraints include required properties, primitive value types, enumerations, cardinality, and allowed relation target types. Prose section guidance is advisory unless an explicit supported constraint says otherwise. Validation establishes structural consistency, not truth.

Custom types can extend imported terms and add local properties or stronger compatible constraints. Preserve external term identities and mappings. Reject cyclic inheritance and conflicting inherited constraints. Do not treat an external vocabulary's suggested properties as mandatory without an explicit local constraint. Entries record their applicable type-definition versions so validation and queries remain reproducible.

Bulk adoption imports the selected ontology's complete supported vocabulary rather than requiring manual adoption of individual terms. Record the source, namespace, pinned version or immutable snapshot digest, and imported dependencies. Preview term counts, identity collisions, dependencies, and unsupported constructs before activation. Never silently discard unsupported semantics or claim reasoning capabilities that the importer does not implement. Activation requires an authorized adoption decision and an explicit disposition for unsupported constructs. Repeat adoption of the same snapshot is idempotent. A newer snapshot is a reviewed upgrade, not an automatic replacement. The initial adoption uses a pinned published Schema.org release, recording its release identifier, release artifact source, and immutable snapshot digest. Never resolve the initial vocabulary from a moving latest or development endpoint. The exact release identifier and supported import formats remain implementation decisions.

Build the six initial local types and their enforced constraints on this imported vocabulary. Preserve Schema.org term identities and keep local additions namespaced separately. Importing suggested domains and ranges does not automatically make every suggested property required. Make the bulk-imported vocabulary discoverable, while presenting Person, Project, Claim, Decision, Procedure, and Evidence as the initial authoring choices.

PROV-O provenance and SKOS concept organization are later extensions, not initial import dependencies. Reserve namespace and version support for combining these vocabularies without requiring their adoption or implementation now. Local evidence references and named relations remain available in the initial release.

Incomplete drafts and proposals expose validation diagnostics to authors and agents. Acceptance and authorized direct writes into curated knowledge validate the complete resulting entry against the selected accepted type versions after applying sets, unsets, replacements, and relation changes, before publishing any accepted revision. Invalid updates leave the accepted revision unchanged. Ordinary untyped notes remain supported. Type definitions and ontology adoption records use the same review, capability, history, and provenance rules as curated content.

Keep prose wikilinks for navigation. Named relations reference stable note identities, with titles and aliases for display. Relations can connect entities and knowledge objects, including Claim supported_by Evidence, Decision affects Project, Decision supersedes Decision, and Procedure maintained_by Person. The initial local constraints below make these relationships enforceable without choosing external mappings prematurely. An unresolved prose link can remain navigable as a dangling link, but a required typed relation must resolve to an accepted, type-compatible target or a compatible entry accepted in the same atomic transaction.

Agents can propose a page's prose, properties, and relations as one reviewed mutation with evidence. Schema changes invalidate affected pending acceptance eligibility. Normal queries and graph traversal use accepted entries and accepted relations under the caller's effective access policy. Suggested relations and inferred claims remain outside accepted recall until accepted. Derived indexes are rebuildable from accepted notes, relation records, and pinned type definitions.

Type upgrades preview affected entries and validation failures. Existing entries retain their prior type versions until an explicit reviewed migration succeeds. Imports, upgrades, and migrations must not silently reinterpret or invalidate existing accepted knowledge. Renames preserve relation targets. Target deletion or type migration must reject an operation that would break enforced accepted relations unless an authorized coherent migration resolves those relations.

## Shared agent tool contract

Expose one service contract through REST, MCP, Hermes, future adapters, and the extraction worker. Tool names below describe the planned knowledge surface, separate from existing ordinary-note tools. Adapters translate arguments and results without changing validation, authorization, query visibility, or idempotency semantics. Every call specifies a vault and uses trusted credential identity; client labels cannot increase permissions.

| Operation | Required inputs | Result |
|---|---|---|
| `list_knowledge_types` | vault; optional namespace, cursor, limit | Accepted type identities, versions, descriptions, and next cursor |
| `get_knowledge_type` | vault, type ID; optional pinned version | Accepted definition with resolved inherited constraints, guidance, origin, and version |
| `query_knowledge` | vault; optional types, property filters, relation filters, sort, cursor, limit, traversal | Accessible accepted entries with stable IDs, accepted revisions, pinned type versions, matching relations, and next cursor |
| `inspect_source` | vault, source ID, immutable revision; optional locator | Authorized revision metadata and bounded text excerpt, or a scoped attachment reference for non-text content |
| `validate_knowledge_candidate` | vault, atomic candidate operations, pinned types, expected bases | Validity flag, field and operation diagnostics, resolved references, and checked revisions; no writes |
| `propose_knowledge` | vault, idempotency key, atomic candidate operations, pinned types, expected bases, evidence references | Durable proposal ID, proposal revision, state, and structural diagnostics |
| `get_knowledge_proposal` | vault, proposal ID | Authorized candidate, state, diagnostics, evidence, and review activity |
| `amend_knowledge_proposal` | vault, proposal ID, expected proposal revision, idempotency key, replacement candidate | New retained proposal revision, state, and diagnostics; changed content invalidates prior approval |

Read operations require applicable knowledge-read or explicit source-read authority. Validation additionally requires proposal authority and access to all referenced inputs, so it cannot act as a hidden-content oracle. Proposal writes require proposal authority. None of these tools grants review or accepted-edit authority. Proposal inspection follows effective review-record access rather than ordinary accepted-note access. Inaccessible and absent references return the same public not_found response; authorized owners can inspect source purge status through explicit evidence inspection.

Queries accept a list of pinned type references, conjunctive property conditions using eq, neq, contains, is_empty, is_not_empty, gt, gte, lt, or lte, and conjunctive named relation conditions with target IDs or target type references. Reuse existing database operator semantics where applicable and reject unsupported field/operator pairs. Sort by declared properties or built-in fields with stable ID as a tie-breaker. Default limit is 50, maximum 200. Optional outgoing relation traversal selects relation names and has max_depth from 0 to 2 and max_nodes from 1 to 200; return a truncated flag when bounded. Default traversal depth is zero. Do not expose an arbitrary graph query language initially.

Opaque cursors bind normalized query arguments, vault, and an accepted index revision. If that revision no longer supports consistent continuation, return cursor_stale and require restart. Recheck access for every page and traversed node. Hidden or pending nodes must not influence returned counts, relation paths, or traversal results. Responses distinguish accepted domain Decision status from proposal review state.

Candidate operations are create and update knowledge entries, each with a unique local_ref, explicit type references, Markdown content, property sets and unsets, and named relation additions and removals. Updates identify the stable entry ID and expected accepted revision; targeted block operations also identify expected block revisions. Whole-entry replacements require the whole-entry base revision. New relations may target existing IDs or local_ref values within the same candidate group. Evidence references use the source revision and locator file contract. The service serializes resulting files, so agents need not construct frontmatter or filesystem paths. Type-definition and policy mutations remain outside this initial knowledge proposal operation set.

Validation evaluates the complete resulting group, reports errors by operation, field, constraint, and reference, and never grants later acceptance eligibility. Structurally incomplete groups may be stored as proposals with diagnostics, but malformed operations, inaccessible references, and unauthorized writes fail before persistence. Submission checks expected bases and records them; acceptance rechecks touched bases, type versions, source access, and effective policy. Amendments retain prior candidate versions and require the current proposal revision. Multi-entry acceptance publishes all operations atomically or none, including after recovery.

Scope idempotency keys by vault, authenticated principal, and operation. Record a canonical payload digest with the durable proposal revision and response. Repeating the same key and payload returns the original proposal or amendment result even after a lost response; a different payload returns idempotency_conflict. The idempotency record and proposal persistence share one recoverable transaction. Authorized purge may erase response content but retains a non-content consumed-key tombstone so retries cannot recreate purged proposals. No tool retry silently creates another candidate group.

Use common structured errors across adapters: not_found, forbidden for denied operations, validation_failed, version_conflict, idempotency_conflict, cursor_stale, and temporarily_unavailable. Tool descriptions publish argument shapes, supported filters, bounds, evidence encoding, and permissions. Hermes and the background worker invoke this same contract; the worker retains proposal-only authority.

## Initial local constraints

All six types require the existing non-empty note title and an explicit pinned type assignment. Person additionally requires a non-empty display_name. Project requires a non-empty summary. Claim requires a non-empty statement and at least one supported_by relation to Evidence. Decision requires a non-empty rationale, one decision_date, a status from proposed, accepted, or superseded, and at least one affects relation to Project. Procedure requires at least one non-empty ordered step and at least one maintained_by relation to Person. Evidence requires one source reference, one immutable source revision identifier, and one non-empty locator identifying a passage or explicitly the whole source. Date values use the existing date encoding. Decision status describes the domain decision, independently of document review state.

Optional relations have cardinality zero or more: Project maintained_by Person, Decision supported_by Evidence, Decision supersedes Decision, and Procedure supported_by Evidence. Supplied optional relations must also resolve to accepted compatible targets. Evidence source references resolve to authorized retained source revisions, not to knowledge targets. These are minimal structural requirements; inherited Schema.org suggestions remain advisory unless explicitly constrained.

Serialize relation acceptance, target deletion, and type migration across affected stable identities, or use an equivalent transaction. Validation and publication must share the integrity boundary so concurrent operations cannot leave accepted dangling or incompatible relations. Cross-document migrations publish coherently and recover before serving queries. A source-note lock alone is insufficient.

## Implementation order and tracking

1. #368 records this specification and dependency plan.
2. #369 adds trustworthy capabilities and policy enforcement across server adapters.
3. #349 adds immutable revisions, restore, deletion recovery, and explicit purge.
4. #370 adds stable block identity against accepted revisions.
5. #371 adds evidence-backed proposals, comments, decisions, and acceptance.
6. #372 adds review and history to the existing editor.
7. #344 integrates explicit memory destinations; #348 integrates provenance and supersession with proposals.
8. #345 adds optional evidence capture; #346 adds durable retries; #347 improves scoped passage recall.
9. #350 measures quality and #351 exposes health independently.

Ontology adoption, reusable type definitions, typed relations, validation, query integration, and authoring diagnostics need focused implementation tracking after the existing foundations. No issue numbers or completed runtime work are claimed for this extension.

Independent foundations can proceed in parallel. Dependent PRs must name their base and remain independently verifiable. Feature PRs receive their own issue and specification changes; this design PR does not claim to close implementation issues.

## Risks and verification

The main risks are falsely trusted identities, ambiguous Markdown matching, cross-store crash consistency, incomplete authorization across read paths, and unapproved evidence entering normal recall. Verify behavior with deterministic concurrency and failure injection, real storage/index tests, adapter authorization tests, and isolated Flutter verification for the review UI. Preserve existing ordinary-note workflows and define migration before enabling curated policies.

Verify the typed extension with import idempotency and unsupported-construct cases, inheritance conflicts, acceptance validation, stable relation targets, access-filtered graph queries, and versioned migration failures.
