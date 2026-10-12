## Why

PR #391 already implemented curated permission enforcement for #369 in `enforce-curated-permissions`. The expanded knowledge workflow needs regression verification of that foundation and authorization integration in the new services, not a second policy implementation.

## What Changes

- Verify the merged policy resolution, adapter enforcement, trusted principals, and compatibility contract.
- Define integration obligations for new type review, source ingestion, typed proposals, queries, and extraction services.
- Fix only demonstrated regression gaps using the existing policy service; preserve completed #369 scope.

## Capabilities

### New Capabilities

- `curated-curated-knowledge-policy`: Verified reuse of the merged policy contract by new knowledge services.

### Modified Capabilities

None. Existing policy resolution and adapter contracts remain authoritative.

## Impact

Dependencies: completed `enforce-curated-permissions` from PR #391, scoped credentials, revision history, and stable blocks. New service integration belongs to each owning slice. This verification change gates integrated release, not construction of proposal review. No new issues are filed and #369 is not reopened.

## Non-goals

Reimplementing policy overlays, existing adapter enforcement, or completed #391 behavior. Other implementation slices, PROV-O, SKOS, and autonomous gardening remain out of scope.
