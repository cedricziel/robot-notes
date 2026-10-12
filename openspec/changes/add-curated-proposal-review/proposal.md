## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Persist block proposals and review decisions supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Build the durable proposal and review store on existing immutable revisions and stable block identities. Preserve proposal amendments, comments, denied history and stale anchors; accept unchanged disjoint blocks and require re-review for overlapping edits.

## Capabilities

### New Capabilities

- `curated-curated-proposal-review`: Persist block proposals and review decisions.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: completed `enforce-curated-permissions` (PR #391). Existing tracking: #371. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
