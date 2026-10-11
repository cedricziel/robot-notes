## API and target types

Existing-note creation is `POST /notes/{id}/proposals`. A separate `POST /notes/proposals` creates a new-note draft with target `{kind: new_note, path, title, properties, content}`. The server reserves its opaque note ID; it creates no canonical Markdown until acceptance. Prospective folder policy is resolved by the shared permissions API before submission. Draft target paths are checked again under the existing canonical path lock at acceptance. Institutional drafts outside a curated folder require the reviewer to have policy authority to designate the new note curated with default human governance, in addition to review authority. No institutional label creates accepted ordinary content.

Use `GET /notes/{id}/proposals` to list proposals and `GET /notes/{id}/proposals/{proposal_id}` to inspect a versioned record. Amendments, comments, and review decisions use explicit sibling endpoints. MCP mirrors these operations and exposes accepted block maps for constructing precise operations. Caller identity always comes from the authenticated principal, never request author fields or actor headers.

Submission captures `proposal_revision`, author principal ID, base note version, exact base block IDs and revisions, ordered operations, evidence references, policy revision, and policy fingerprint. The candidate `proposal_revision` is separate from the monotonic `record_revision` used for concurrent comments and decisions. A caller-scoped idempotency key deduplicates durable retries and rejects reuse with different input. Amendments require the latest proposal revision and retain previous proposal versions.

## Operations and exact source

Block operations are `replace`, `delete`, `insert_after`, and `attach_evidence`. An exclusive `delete_note` operation checks the exact whole-note base version and all block revisions before producing a retained deletion tombstone; it never implies purge. Content operations name an existing block ID and expected revision. Insertions also capture accepted adjacent anchor identities so concurrent insertions into the same gap cannot claim disjoint edits. Inserted Markdown contains its intended separators; the server never rewrites source formatting.

Compute edits against the current accepted map while holding the note lock. Apply replacements in source order without changing untouched text or whitespace gaps. Server-derived identity hints preserve unaffected duplicate spans and explicit supported singleton replacements; clients cannot submit identity overrides. Split, merge, compound, or structural ambiguity requires fresh IDs and re-review. A candidate that changes undeclared neighboring structure is refused until its touched set is explicitly revised.

Disjoint newer note revisions do not block acceptance when touched block revisions, insertion anchors, evidence checks, and effective policy still match. Stale or removed touched blocks become conflicted or need re-review. A whole-note human edit invalidates proposals overlapping changed, retired, or ambiguous identities. Raw external rewrites make block metadata unavailable and prevent acceptance until a supported accepted save establishes metadata.

## State and review activity

States are `pending`, `changes_requested`, `needs_re_review`, `conflicted`, `accepted`, and `denied`. A valid amendment returns a non-terminal proposal to pending and invalidates prior approval. Accepted and denied records remain terminal; a new proposal records subsequent work.

Comments are immutable events with a stable thread ID, trusted author ID, text, proposal revision, and an optional accepted or proposed block anchor. Replies name an existing thread in the same proposal. Old comments remain inspectable after amendments or deleted blocks and carry stale or orphaned anchor status.

An authorized human decision is `approve`, `deny`, or `request_changes`. Approval accepts all operations together. Partial approval requires an amendment or separate proposal. Concurrent or repeated approval cannot create multiple accepted revisions. A stale decision fails without publishing accepted content; the latest proposal state remains inspectable.

## Evidence and accepted provenance

The first immutable resolvers support accepted note revisions and accepted block revisions in the selected vault. Resolution checks read access at the live resource and referenced historical resource, validates retained content and source block freshness, and records exact source identity. External URLs, explicit unknown sources, and conversation lineage identifiers remain unverified references and are ineligible for automatic acceptance. Archive evidence requires an explicitly supplied digest, selected-vault evidence read authority, and a live non-expired record; digest existence alone establishes no truth. References do not become a competing fact store.

Accepted evidence associations and supersession references attach to accepted block identities in revision sidecar metadata. `attach_evidence` changes that provenance without changing accepted Markdown. Normal search, links, database rows, embeddings, and recall read accepted content only. Proposal inspections expose candidate text and evidence explicitly.

Automatic acceptance requires explicit `evidence_no_conflict` policy, an authorized proposer, validated source evidence, current touched blocks, unchanged effective policy, and a verified supported eligibility result. Mere evidence existence or disjoint spans do not prove semantic consistency. The default verifier abstains for arbitrary text changes. The only automatic class is nonempty `attach_evidence` operations with fully resolved, accessible immutable note or block revisions, or live archive evidence. They leave accepted Markdown and block revisions unchanged and record source linkage without asserting claim truth. Unknown, conversation, and URL references remain pending, as do text changes, deletion, new notes, and supersession claims. A source that becomes unavailable during verification leaves its durable proposal pending.

## Authorization and atomic acceptance

Use `NoteAuthorizationService.require` and the shared reentrant policy mutation lock. Submission and amendment require read and propose rights at the resolved target. Comments require read plus propose or trusted human review rights; final decisions require read and trusted human review rights. Known agent credentials cannot gain human review authority through extra scopes. Client adapters with known agent context always use proposals for curated knowledge, including when legacy operator credentials are still configured.

Capture and recheck policy revision and effective fingerprint. Read access also applies to evidence sources and proposal inspections. A private typed acceptance permit is issued only after real review or verified automatic eligibility. No client JSON field, public principal override, or actor label can issue that permit.

Keep proposal records and events inside the note's retained history directory, outside canonical content and disposable indexes. Explicit history purge erases proposal candidates, comments, decisions, and older snapshots. A live note with required history keeps its current accepted snapshot, block map, and self-contained active provenance; a deleted note loses all retained note history. The independent evidence archive follows its own retention contract.

The pending journal contains candidate canonical text, accepted revision, block map, accepted provenance, minimal authorized policy delta, and the final proposal record. Numeric immutable snapshots omit transaction-only proposal and policy deltas; replay applies them from the pending journal before clearing it. Public revision reads also use an accepted-field projection. Replay writes the same opaque IDs and immutable decision events before serving content. An interrupted publication blocks accepted content and proposal inspection until replay completes. Only a committed acceptance updates normal derived indexes; index-pending tickets remain until the corresponding update succeeds.

Restore creates a new accepted revision with the selected snapshot's active provenance. It preserves prior proposal and decision history until explicit purge; restoring before an automatic source attachment removes that current attachment without changing the historical accepted record. It invalidates overlapping live proposals through the same block transition checks. A deleted note keeps historical review records; a draft never creates a searchable placeholder note.

## Verification

Use real filesystem and search components with deterministic failure injection. Verify exact source, explicit duplicate identities, disjoint merges, same-block and gap conflicts, immutable comments and amendments, caller-scoped idempotency, policy changes during review, known-agent denial, evidence access, new-note path collisions, crash replay, accepted-only retrieval, and explicit purge. Use bounded test batches to limit native compiler temporary storage.
