## Why
Agents need to propose curated knowledge changes without publishing them as accepted content. Review needs stable block anchors, durable evidence references, and atomic multi-block acceptance.

## What Changes
- Add versioned existing-note proposals and explicit new-note drafts.
- Add block replacements, deletions, anchored insertions, and evidence attachments.
- Persist comments, amendments, and human review decisions with the note's retained history.
- Merge disjoint accepted updates and invalidate overlapping or ambiguous reviews.
- Apply the shared trusted-principal policy service to submission, inspection, review, and acceptance.

## Impact
Depends on #349, #370, #369, and trusted credential capabilities. One PR implements #371; editor review UI and memory adapters follow separately. Automatic acceptance is limited to verified source attachments that leave accepted Markdown unchanged. Text changes and new notes always require human review.
