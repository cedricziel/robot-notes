## Context

PR #387 merged the umbrella contract in `add-curated-knowledge`. Existing revision retention, stable block identities, scoped credentials, Hermes identity scope, and durable memory retries are available foundations. Planning completion is not runtime completion.

## Goals / Non-Goals

**Goals:** Implement the requirements in this change's delta spec with one bounded service contract and focused adapter changes.

**Non-Goals:** Implement sibling slices, alter ordinary note behavior incidentally, or enable the full feature before the release gate passes.

## Decisions

Add review/history and typed authoring assistance to the existing Flutter editor. Show accepted content by default, explicit pending groups, validation diagnostics, type guidance, sources and evidence context. Preserve Markdown editing and enforce server permissions.

Reuse the umbrella document formats and service contracts rather than introduce parallel stores or adapter-specific semantics. Stage externally visible functionality behind explicit enablement so each foundation can land safely. Reuse existing history and credential primitives; add regression checks instead of rebuilding completed foundations.

Dependencies: `add-atomic-typed-knowledge-proposals`, `add-knowledge-agent-tools`. Dependencies must provide their verified service contract before this slice enables its dependent operations. Existing issue alignment: #372. No additional issues are filed by this planning change.

Implement tests before behavior in each task pair. Keep conventional commits coherent and use focused PRs, preferably below 500 lines; split a slice into service, adapter, or verification PRs when needed. Dependencies describe semantic order, not a requirement to build a single long-lived branch stack.

## Risks / Trade-offs

Partial deployment may expose incomplete semantics. Keep new operations disabled or return explicit capability diagnostics until prerequisites are available. Authorization, crash recovery, and compatibility require real integration checks; mocked tests alone do not satisfy the release gate.

## Migration Plan

Land foundations with new behavior disabled. Preserve existing data and index encodings, use explicit versioned migration when accepted data changes, and rebuild only derived indexes. Roll back feature enablement without deleting retained sources, accepted snapshots, or proposal history. Follow the umbrella purge contract for any explicit erasure.

## Verification

Exercise this slice's scenarios with deterministic failure and authorization cases where applicable. Record relevant formatting, lint, tests, and strict OpenSpec validation. For app or Hermes flows use isolated real-server verification with disposable data and test principals. Integrated feature activation requires `verify-curated-hermes-release`; this slice does not independently claim full release readiness.
