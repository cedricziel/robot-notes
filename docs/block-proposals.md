# Block proposals and review

Proposals hold candidate knowledge separately from accepted Markdown. Normal notes, search, links, database queries, embeddings, and recall contain accepted content. New-note proposals reserve a note ID without creating a placeholder note.

## Construct an existing-note proposal

Read the note body and `GET /notes/{id}/blocks`. The note version must match the map version, and the map's SHA-256 `content_hash` must match the exact UTF-8 body. Block offsets use UTF-16 code units, including for emoji. MCP `get_note_blocks` reads body, map, and active provenance together under one lock.

Submit `POST /notes/{id}/proposals`:

```json
{
  "base_version": 4,
  "idempotency_key": "caller-generated-retry-key",
  "operations": [
    {
      "type": "replace",
      "block_id": "opaque-accepted-block-id",
      "expected_revision": 2,
      "text": "Exact replacement Markdown\n"
    }
  ],
  "evidence_refs": [
    {"kind": "unknown", "reason": "source_not_recorded"}
  ]
}
```

The server never inserts separators or reformats text. Operations are `replace`, `delete`, `insert_after`, `attach_evidence`, and the exclusive whole-note `delete_note`. Insertions name an accepted block and its revision; the server captures the following gap and inserts at its end. A null block anchor is allowed only for an empty block map and inserts after existing whitespace. `delete_note` requires the exact whole-note base version and produces retained history rather than purging it.

Submission returns `proposal_id`, `note_id`, `proposal_revision`, `record_revision`, `state`, and `accepted`. `accepted_version` appears only after committed acceptance. Retry keys are scoped to the trusted proposer and target. Reusing a retained key with different input returns a conflict.

## Create a reviewed note

Submit `POST /notes/proposals` with `path`, `title`, exact `content`, optional `properties` and `evidence_refs`, and an `idempotency_key`. `curated_intent` defaults to true. The response reserves a stable note ID; ordinary note retrieval still returns not found until acceptance.

An institutional draft outside a curated folder requires the human reviewer to have both review and policy authority. Acceptance designates it curated with human approval by default. The server rechecks policy and canonical path collisions before publication.

## Inspect, comment, and decide

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/notes/proposals` | Readable vault review index, including drafts |
| GET | `/notes/{id}/proposals` | Note review summaries |
| GET | `/notes/{id}/proposals/{proposalId}` | Candidate, retained versions, events, and own allowed actions |
| PUT | `/notes/{id}/proposals/{proposalId}` | Complete candidate amendment with proposal and record CAS |
| POST | `/notes/{id}/proposals/{proposalId}/comments` | Immutable proposal comment or reply |
| POST | `/notes/{id}/proposals/{proposalId}/decisions` | Approve, deny, or request changes |
| GET/POST | `/notes/{id}/comments` | Separate accepted-block threads |

Lists return `{items:[...]}`. Summaries include target `title`, `path`, and `new_note`, with `accepted` derived solely from committed state. Display labels, credential kind, and agent origin do not authorize actions. Use `?state=accepted` to inspect accepted automatic changes, or `?include_terminal=true` for accepted and denied audit records. Draft inspection includes `draft:{title,path,content,properties,curated_intent}`.

Decisions send `{decision,record_revision,comment?}`. Amendments require both `proposal_revision` and `record_revision`; earlier candidates remain retained. Comments send `{record_revision,body,block_id?,block_revision?,reply_to?}`. Standalone accepted comments require a current block anchor for a new thread, with initial record revision zero. Replies preserve the original thread anchor. Anchor status becomes stale or orphaned after revisions or deletion.

Submission and amendment require read and propose authority. Comments require read plus propose or trusted human review authority. Final decisions require trusted human review authority; an agent cannot gain it through display labels or extra agent scopes. The restrictive `X-Robot-Notes-Agent: true` marker also denies human actions for legacy operator or OAuth credentials while preserving their recorded identity. Audit records expose `author_agent_origin` separately from `author_kind`. Inspection also checks historical candidate target access. `allowed_actions` describes the current caller's permitted actions.

Approve is available only for fresh `pending` or `changes_requested` candidates. Overlapping accepted changes, insertion gaps, unavailable block maps, or policy changes require amendment and re-review. Disjoint accepted block changes can merge. Accepted and denied records remain terminal; comments remain appendable by authorized callers.

## Sources and automatic attachments

Evidence references identify accepted `note_revision` or `block_revision` coordinates, an explicit archive SHA-256 `digest`, a URL, conversation lineage, or an explicit unknown source. Archive evidence must still be live and readable in the selected vault. Source existence establishes linkage, not claim truth. Historical note sources require access at both current and retained locations.

Only explicit `evidence_no_conflict` policy can automatically accept nonempty `attach_evidence` operations with fully resolved accessible immutable sources. They preserve accepted text and block revisions. Text edits, new notes, deletion, supersession claims, URLs, conversation lineage, and unknown sources remain pending for human review. Evidence that expires during verification leaves the durable proposal pending.

Active evidence and supersession links attach to accepted block identities in each accepted revision. A restore copies the selected snapshot's active links into a new revision, so a restored-away automatic attachment stops being active while its original accepted record remains historical.

## Recovery and purge

Acceptance journals canonical Markdown, accepted maps and provenance, authorized designation deltas, and final review state. An interrupted publication blocks content and proposal inspection until restart replay finishes. Replay uses the same reserved block IDs and decision events. Derived views update only after publication, with index tickets retained if indexing fails.

Numeric accepted snapshots omit pending proposal and policy transaction copies. Public history reads expose accepted fields only. Explicit authorized purge removes old accepted revisions and all proposal/comment audit data. Live notes with required history keep their current accepted snapshot, map, and active provenance. Deleted-note purge removes all retained note history. Purge deliberately removes historical undo and retained retry keys; it does not turn source coordinates into retrievable evidence.
