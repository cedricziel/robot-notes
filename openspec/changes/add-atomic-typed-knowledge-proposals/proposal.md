## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Validate and accept atomic typed candidate groups supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Add structured create/update groups with local references, expected revisions, Markdown, properties and named relations. Validate complete resulting entries including unsets. Persist idempotent proposal/amendment results and accept groups transactionally across source and target identities with crash recovery.

## Capabilities

### New Capabilities

- `curated-atomic-typed-knowledge-proposals`: Validate and accept atomic typed candidate groups.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-curated-proposal-review`, `add-filesystem-knowledge-types`, `add-versioned-knowledge-sources`. Existing tracking: Extends #371; #348 evidence lineage. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
