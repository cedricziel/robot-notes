## Scope and source preservation
Block maps are captured for notes with accepted revision history. The body stays verbatim. Offsets use Dart string indices, which are UTF-16 code units. Gaps, whitespace, CRLF, and a missing final newline remain ordinary source text and are never rewritten by the parser.

Recognize top-level headings, paragraphs, thematic breaks, and fenced code. Lists, tables, block quotes, and indented code remain indivisible spans. Unrecognized embedded or HTML constructs consume the remaining source as an opaque span, because a blank line does not prove that their contents have ended.

## Identity and reconciliation
Every new block receives an opaque ULID and revision 1. An unchanged body keeps all IDs, including repeated blocks. Across a changed body, unique exact spans retain identity even when moved. Only a same-kind singleton replacement between the same unchanged neighbors retains an edited block's ID and increments its block revision. Changed opaque spans, duplicate text, splits, merges, and uncertain replacements receive new IDs. Reconciliation lists retired IDs and ambiguous IDs so later review code cannot mistake an uncertain correspondence for a stable anchor.

Source hashes verify freshness and never serve as IDs. A map whose body hash differs from its accepted source cannot supply identity matches. Direct external rewrites receive fresh IDs on the next accepted save. No guarantee applies to export/import that omits sidecar metadata.

## Accepted persistence and migration
Store each map in its accepted revision snapshot, outside canonical content and search. The pending history event includes candidate maps before canonical publication, so restart publishes the same IDs rather than generating replacements. Deleted revisions have no live blocks. Restores reconcile against the latest live accepted map, or create fresh IDs after deletion. Purge erases retained maps with retained history; subsequent capture establishes fresh IDs.

Legacy immutable snapshots without maps remain unchanged. A first accepted save establishes identities for its new revision. Inspection reports unavailable for an older revision without metadata. Read requests never alter accepted history.

## Inspection and authorization
`GET /notes/{id}/blocks` returns a current accepted block map, or a retained map when `version` is supplied. Existing read scope and vault authorization apply. A missing note or revision returns 404; an accepted revision predating maps returns 409 with `block_map_unavailable`. Pending maps never appear as accepted metadata.
