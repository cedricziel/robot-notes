## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Enforce curated policy across all adapters supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Resolve vault and nearest-folder policy with explicit note overrides. Centralize trusted capability checks across ordinary note writes, properties, move, restore, REST, MCP, WebSocket events, search and database rows. Agent credentials remain proposal-only for curated knowledge.

## Capabilities

### New Capabilities

- `curated-curated-knowledge-policy`: Enforce curated policy across all adapters.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: existing scoped credentials, revision history, and stable block identity. Existing tracking: #369. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
