# Stable Markdown block identities

Notes with accepted revision history capture block maps when they save. Set `history: true` to enable that history. Ordinary notes and older accepted revisions without maps return `block_map_unavailable` to plain readers; their metadata is established by a later accepted save. When a caller allowed to propose reads the current map of a note that has no snapshot yet, or submits a proposal against it, the server captures a baseline map for the current version first (content and version stay unchanged, and the note keeps revision history from then on). Stale maps are never replaced this way.

`GET /notes/{id}/blocks` returns the current accepted map. Add `?version=N` to inspect a retained accepted revision. Requests require the existing note read scope and vault grant. The map contains opaque IDs, per-block revisions, kinds, exact UTF-16 start and end offsets, and source hashes. Hashes verify freshness and never identify blocks.

Markdown stays unchanged. Blank-line gaps remain in the source. Headings, paragraphs, and thematic breaks can retain identity through an unambiguous edit between stable neighboring blocks. Unique unchanged spans keep their IDs when moved. An unchanged document preserves repeated-block IDs.

After a document changes, repeated text, splits, merges, and changed compound constructs receive fresh IDs. `retired_ids` names vanished identities. `ambiguous_ids` identifies prior anchors that require re-review. `changed_ids` names retained identities whose block revisions increased. Lists, tables, quotes, and code stay indivisible. Unknown embedded or HTML constructs consume the remaining source as an opaque block.

Maps are immutable accepted-revision metadata outside canonical Markdown and normal search. A pending journal includes candidate IDs before publication, so restart recovery publishes the same identities. Stale saves leave maps unchanged. Restore reconciles against the latest live map; restore after deletion establishes fresh IDs. Purge removes retained maps with retained history.

Direct external Markdown edits can invalidate the current map. Current inspection returns `block_map_stale` without generating IDs or altering history. A later supported save establishes a conservative fresh map. Portable export/import that omits sidecars does not preserve identities. Proposal, comment, and policy workflows are separate features.
