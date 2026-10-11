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

Independent foundations can proceed in parallel. Dependent PRs must name their base and remain independently verifiable. Feature PRs receive their own issue and specification changes; this design PR does not claim to close implementation issues.

## Risks and verification

The main risks are falsely trusted identities, ambiguous Markdown matching, cross-store crash consistency, incomplete authorization across read paths, and unapproved evidence entering normal recall. Verify behavior with deterministic concurrency and failure injection, real storage/index tests, adapter authorization tests, and isolated Flutter verification for the review UI. Preserve existing ordinary-note workflows and define migration before enabling curated policies.
