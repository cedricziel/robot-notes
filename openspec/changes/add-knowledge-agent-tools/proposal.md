## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Expose accepted queries and shared agent tools supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Expose the umbrella tool contract through REST and MCP with shared services: type discovery, accepted queries, source inspection, candidate validation, submit/get/amend proposals and server capability discovery. Bound traversal and pagination and avoid hidden-content or pending-data leaks.

## Capabilities

### New Capabilities

- `curated-knowledge-agent-tools`: Expose accepted queries and shared agent tools.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-atomic-typed-knowledge-proposals`. Existing tracking: No new issue filed. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
