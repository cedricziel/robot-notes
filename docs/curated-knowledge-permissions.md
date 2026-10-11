# Curated knowledge permissions

Ordinary notes remain ordinary by default. An authorized human designates a note or folder as curated through the policy API. Curated designation, approval rules, and access lists live in `knowledge-policy.json` under the server data directory, outside editable Markdown. Changing note properties or body text cannot remove protection.

## Identity and capabilities

The server derives identity from the authenticated credential: `operator`, `agent:<credential ID>`, or `oauth:<grant ID>`. OAuth refresh preserves the grant ID. Actor names remain attribution, never authorization. Use [scoped agent credentials](scoped-agent-credentials.md) when onboarding or migrating agents.

| Action | Required capability and authority |
| --- | --- |
| `read` | `notes:read`, selected vault access, and effective read ACL |
| `propose` | Read access plus `knowledge:propose` and proposal ACL |
| `review` | Read access plus trusted human authority, `knowledge:review`, and review ACL |
| `edit` | Read access plus `notes:write` and edit ACL; curated notes additionally require trusted human authority and `knowledge:edit` |
| `policy` | Read access plus trusted human authority, `knowledge:policy`, and policy ACL |
| `purge` | Read access plus trusted human authority, `knowledge:purge`, and purge ACL |

The configured operator key has full authority. `vaults:manage` alone does not grant knowledge review, accepted editing, policy changes, or purge. Known agent credentials cannot directly edit curated accepted notes or perform human review, policy changes, or purge, even if provisioned with those scopes. Proposal acceptance is a separate internal operation in the proposal service; it does not require ordinary direct-edit authority.

REST and MCP clients can send `X-Robot-Notes-Agent: true`. This flag only restricts authority: it preserves authenticated identity while treating the request as agent-originated. It blocks curated direct editing and human-only actions even when a legacy agent holds the operator key. Omitting or changing the header cannot lift the restrictions of a known agent credential. The flag is not a substitute for replacing distributed operator keys and rotating the key.

Authorization runs in an immutable request context. Missing or expired contexts fail closed. Delayed upload finalization revalidates the recorded issuer and current caller explicitly rather than inheriting an expired request context.

## Inheritance and access lists

Policies merge from the vault root folder through ancestor folders to the note override. Missing fields inherit. A supplied action list replaces the inherited list: `[]` denies the action, and `['*']` admits any credential that also meets the capability and authority requirements. Lists may name stable operator, agent, or OAuth IDs. Folder matching follows the filesystem's case and Unicode collision rules; note overlays remain bound to stable IDs after moves.

A policy patch accepts `curated`, `approval` (`human` or `evidence_no_conflict`), and `access`, an object keyed by the six action verbs. Policy updates replace a local overlay; DELETE resets it to inheritance. They do not edit accepted Markdown.

Moving a note between different effective protections requires policy authority at both locations. Indirect rename propagation checks each destination's rights before rewriting it. Ordinary note deletion requires `edit`; retained history and evidence deletion requires `purge`.

The `evidence_archive` collection has its own access overlay. Raw evidence capture uses read/write and collection ACLs, even when the vault root is curated: captured evidence is not an accepted curated note. Reading a cited digest requires selected-vault and collection read access. Citation or review authority does not grant source access. There are no per-archive ACLs in this version.

## Permission and policy API

All examples use the selected vault's usual request context.

| Endpoint | Result |
| --- | --- |
| `GET /notes/{id}/permissions` | Own capabilities for an existing or retained deleted note |
| `GET /notes/permissions?path=Folder&title=Draft` | Own capabilities for a prospective note; creates no note |
| MCP `get_note_permissions` with `{id}` or `{path,title}` | The same existing or prospective inspection |
| `GET /knowledge/policies?kind=note&id=ID` | Local and inherited note policy for a policy manager |
| `GET /knowledge/policies?kind=folder&path=Folder` | Local and inherited folder policy |
| `GET /knowledge/policies?kind=collection&name=evidence_archive` | Collection policy |
| `PUT /knowledge/policies` | Conditionally replace an overlay |
| `DELETE /knowledge/policies` with the same target query | Conditionally reset an overlay |
| `GET /knowledge/principals` with optional policy target query | Selected-vault credential directory for a policy manager |

Normal note detail also includes `permissions`. Permission inspection returns `id` (null for prospective notes), `path`, `curated`, `approval`, integer `policy_revision`, `policy_fingerprint`, `principal_kind`, `agent_origin`, and `allowed_actions`. Actions are the verbs `read`, `propose`, `review`, `edit`, `policy`, and `purge`; they are not OAuth scope strings.

Curated note inspection reports `requires_human_approval: true` and `agent_text_requires_human_approval: true`. For an existing curated note with `evidence_no_conflict`, `auto_acceptance_classes` contains only `verified_source_attachment`. Otherwise it is empty. That class permits verified source attachment with accepted text unchanged; text rewrites, new notes, and conflicts still require human approval. The proposal service implements the acceptance predicate separately.

Policy inspection returns `target`, nullable `local_policy`, `effective_policy`, `policy_revision`, `policy_fingerprint`, and own `allowed_actions`. Managers need read and human policy authority on the target. The directory envelope is `{items:[{id,label,kind,capabilities}]}`. Capabilities are exact credential scope strings; the operator uses `['*']`. Labels are display text. The directory excludes revoked or expired identities and secrets, hashes, and tokens; capabilities do not imply access through the target ACL.

A conditional update uses the integer revision from inspection:

```http
PUT /knowledge/policies
If-Match: "7"
Content-Type: application/json

{"target":{"kind":"folder","path":"Knowledge"},"policy":{"curated":true,"approval":"human","access":{"propose":["*"],"edit":["operator"]}}}
```

Successful responses include the quoted integer ETag. Missing `If-Match` returns 428 `policy_version_required`; a stale revision returns 409 `policy_version_conflict` with `current_policy_revision`. Authorization failures return 403 `knowledge_access_denied` and the denied action. Old servers without permission inspection cannot establish curated write permission; agent integrations should fail closed for institutional writes.

## Accepted history and purge

Designation initializes accepted history and block identities before publishing policy, under the shared mutation lock. If the current version has no immutable snapshot, capture preserves that accepted version. If an existing immutable snapshot lacks a usable block map, an authorized no-op accepted revision initializes the current map without rewriting the old snapshot. A durable marker outside the purgeable per-note history directory makes history mandatory; editable properties cannot turn it off. Incomplete accepted journals block further content and policy mutations until recovery.

Explicit history purge erases older revisions and the note's proposal versions, audit records, and comments. A live note requiring history retains its current accepted snapshot, block map, and self-contained active provenance as operational state. Deleted-note purge removes all per-note history. Clean retained snapshots remain byte-identical. If a legacy retained snapshot contains transaction-only `baseline`, `proposal_updates`, or `accepted_policy_delta` fields, purge removes those fields while preserving accepted state. Recovery records the version to keep durably, so restart cannot erase the current map accidentally.

Historical reads require the current note's or last tombstone's policy and the retained location's policy. Moving a note into a private folder does not leave its older public path as an access bypass.

## Enforcement audit

| Surface | Enforcement |
| --- | --- |
| REST/MCP note reads and mutations | Shared authorizer; source-reading mutations require read and edit, with explicit proposal/review scope overrides |
| List, search, tags, tree, databases | Readable IDs filtered before pagination, result limits, and aggregate counts; final source checks after asynchronous work |
| Links, backlinks, schema and relation targets | Unreadable referenced targets withheld or denied |
| History, blocks and restore | Current/tombstone plus retained-path read; restore additionally requires edit |
| Files and Markdown attachments | Physical folder, embedded canonical note ID, and referencing accepted-note policies; hidden staging files excluded |
| Direct and staged uploads | Destination edit rights; canonical or suspicious note payloads rejected before publication; staged issuer, vault, and path pinned and revalidated |
| Locks | Read and edit required before acquire, heartbeat, or release |
| WebSockets | Recorded credential identity; note subscription and each forwarded event checked; policy changes close scoped sessions |
| Policy management and purge | Exact human-only capabilities, shared mutation lock and accepted-history recovery barrier |

Attachment ownership reads parse authoritative current accepted bodies, including ordinary links, images, and reference links. They currently scan notes for each file check; file listing and tree counts can therefore cost proportional to files times notes. This version favors authoritative ACL checks over a derived attachment index. Filesystem administrators can alter server data directly and remain outside the HTTP/MCP trust boundary.
