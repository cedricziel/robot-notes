## Why

The merged curated knowledge contract requires this focused implementation slice before feature activation. Extract evidence-backed proposals from enabled sources supplies a bounded part of the contract without treating completed foundations as unfinished work.

## What Changes

- Implement a durable server scheduler and worker for explicitly enabled source scopes. Pin source, originating identity, extractor configuration and type versions. Recheck access and eligibility, resolve entities conservatively and submit proposals through the shared service without acceptance authority.
- Support configurable `session_end`, `completed_turn`, and `both` triggers for conversation sources. Extraction remains opt-in, with `session_end` as the default trigger when enabled.
- Use the bundled skill’s read → compare → classify → propose workflow. Classify findings as new, update, disputed, or no material, retain exact source references, suppress repeated candidates, and leave extracted text pending human review.

## Capabilities

### New Capabilities

- `curated-background-knowledge-extraction`: Extract evidence-backed proposals from enabled sources.

### Modified Capabilities

None. Existing foundations retain their contracts; adapter integration must preserve existing behavior.

## Impact

Dependencies: `add-knowledge-agent-tools`, `add-versioned-knowledge-sources`. Existing tracking: No new issue filed. Shared contracts and affected server, app, or Hermes adapters receive focused implementation PRs.

## Non-goals

Other slices in the dependency plan, PROV-O, SKOS, universal reasoning, and autonomous gardening. This change plans implementation; it does not implement runtime behavior.
