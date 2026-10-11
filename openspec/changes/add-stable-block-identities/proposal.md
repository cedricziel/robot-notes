## Why
Comments and proposals need durable anchors while the raw Markdown editor continues to save whole notes. Content hashes cannot distinguish repeated blocks or retain identity through edits.

## What Changes
- Preserve exact Markdown and derive conservative top-level source spans.
- Persist opaque block IDs, per-block revisions, and reconciliation results with accepted history.
- Expose current and historical block maps through an authenticated inspection route.
- Require future anchors to be reviewed again when correspondence is ambiguous.

## Impact
Depends on #349 and PR #377. No proposal, comment, policy, or editor workflow is introduced here. Maps are captured for notes with accepted history; existing snapshots remain immutable.
