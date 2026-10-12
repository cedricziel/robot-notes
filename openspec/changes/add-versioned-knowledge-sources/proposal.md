## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Ingest immutable sources and revision-specific Evidence supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Separate explicit source imports from opt-in automatic capture. Store descriptors and original blobs with revision locators. Namespace adapter delivery by vault, principal, adapter and event, compare canonical payloads, and retain purge tombstones. Preserve ordinary memory data and recall.

## Capabilities

### New Capabilities

- `curated-versioned-knowledge-sources`: Ingest immutable sources and revision-specific Evidence.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-filesystem-knowledge-types`, `adopt-pinned-schema-org`. Existing tracking: #348; reuse completed #345 capture foundation. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.

Policy prerequisite: completed `enforce-curated-permissions` from PR #391. Reuse its service for ingestion and inspection checks.
