## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Store reusable types as curated filesystem documents supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Implement format_version 1 and the reserved knowledge metadata object. Store local and imported definitions, vocabulary terms and adoption manifests as Markdown documents. Pin inherited definitions; keep external edits as candidates and rebuild indexes offline from accepted snapshots.

## Capabilities

### New Capabilities

- `curated-filesystem-knowledge-types`: Store reusable types as curated filesystem documents.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-curated-proposal-review`. Existing tracking: No new issue filed. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
