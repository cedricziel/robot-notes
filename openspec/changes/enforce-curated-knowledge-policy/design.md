## Context

PR #391 implemented #369 in `enforce-curated-permissions`. The existing policy service, write service, adapter checks, and permission documentation are the foundation for this plan.

## Goals / Non-Goals

**Goals:** Verify that new knowledge services reuse the existing enforcement contract and identify only concrete regression gaps.

**Non-Goals:** Build another policy resolver or repeat completed REST, MCP, and WebSocket implementation work.

## Decisions

Use existing policy resolution and credential-derived principal contexts. This slice audits and verifies; integration checks and calls are implemented inside their owning service slices. Enumerated new boundaries are type candidate review/activation, source ingestion/inspection, typed proposal validation/acceptance, query traversal, and extraction read/submit. Each must check applicable read and mutation capabilities and effective scope through the existing service.

Proposal review consumes completed `enforce-curated-permissions` directly. It does not wait for this regression-audit slice. The final release gate requires this audit and all owning-slice checks to pass.

## Risks / Trade-offs

A closed issue does not prove that future endpoints are protected. Require explicit authorization checks at each new boundary and fix demonstrated failures in the existing service rather than fork its semantics.

## Migration Plan

No policy data migration is planned. Preserve existing overlays and authority. Any discovered regression fix gets its own failing test and atomic commit.

## Verification

Run existing enforcement regressions and audit new boundary test coverage. Confirm source and type operations cannot use ordinary-note writes to bypass review. Record supported revision and results without claiming unimplemented integrations already pass.
