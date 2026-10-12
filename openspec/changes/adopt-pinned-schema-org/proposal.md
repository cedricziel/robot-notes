## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Bulk-adopt a pinned published Schema.org release supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Select and record an explicit published release and supported import format during implementation. Preserve its bytes, digest, term identities and dependencies. Preview collisions and unsupported semantics before reviewed activation; repeat adoption is idempotent and upgrades never silently migrate entries.

## Capabilities

### New Capabilities

- `curated-adopt-pinned-schema-org`: Bulk-adopt a pinned published Schema.org release.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-filesystem-knowledge-types`. Existing tracking: No new issue filed. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
