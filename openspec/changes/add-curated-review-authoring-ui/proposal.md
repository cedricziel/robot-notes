## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Review typed knowledge in the existing editor supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Add review/history and typed authoring assistance to the existing Flutter editor. Show accepted content by default, explicit pending groups, validation diagnostics, type guidance, sources and evidence context. Preserve Markdown editing and enforce server permissions.

## Capabilities

### New Capabilities

- `curated-curated-review-authoring-ui`: Review typed knowledge in the existing editor.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-atomic-typed-knowledge-proposals`, `add-knowledge-agent-tools`. Existing tracking: #372. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
