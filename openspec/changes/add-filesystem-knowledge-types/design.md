## Context

PR #387 merged the umbrella contract in `add-curated-knowledge`. Existing revision retention, stable block identities, scoped credentials, Hermes identity scope, and durable memory retries are available foundations. Planning completion is not runtime completion.

## Goals / Non-Goals

**Goals:** Implement the requirements in this change's delta spec with one bounded service contract and focused adapter changes.

**Non-Goals:** Implement sibling slices, alter ordinary note behavior incidentally, or enable the full feature before the release gate passes.

## Decisions

Implement format_version 1 and the reserved knowledge metadata object. Store local and imported definitions, vocabulary terms and adoption manifests as Markdown documents. Pin inherited definitions; keep external edits as candidates and rebuild indexes offline from accepted snapshots.

Reuse the umbrella document formats and service contracts rather than introduce parallel stores or adapter-specific semantics. Stage externally visible functionality behind explicit enablement so each foundation can land safely. Reuse existing history and credential primitives; add regression checks instead of rebuilding completed foundations.

Dependencies: `add-curated-proposal-review`. Dependencies must provide their verified service contract before this slice enables its dependent operations. Existing issue alignment: No new issue filed. No additional issues are filed by this planning change.

Implement tests before behavior in each task pair. Keep conventional commits coherent and use focused PRs, preferably below 500 lines; split a slice into service, adapter, or verification PRs when needed. Dependencies describe semantic order, not a requirement to build a single long-lived branch stack.

Local type constraints can be verified against pinned import fixtures here. Production activation of the six Schema.org-based definitions belongs to `adopt-pinned-schema-org`, after their imported parents are accepted.

## Type candidate review boundary

A dedicated type-definition review service owns validate_type_candidate, propose_type_definition, inspect_type_proposal, amend_type_proposal, and authorized accept_type_proposal operations. These are service contracts for type documents, not additions to the initial knowledge-entry proposal operation set. Reuse the review core's durable history, principal checks, amendment freshness, and default human approval. Proposal-only agents can submit candidates; acceptance requires review authority and rechecks inherited policy, definition versions, and constraint compatibility. Publication changes accepted type files and their retained snapshots atomically before rebuilding indexes.

The Schema.org importer submits a bulk adoption candidate to this service. The candidate groups the retained artifact, manifest, imported terms, and local definitions with stable version references. Adoption inspection exposes dependencies, collisions, unsupported dispositions, and migration impacts. Authorized adoption acceptance publishes that complete group atomically after revalidation; retries reuse candidate identity. It does not invoke knowledge-entry proposals or expose direct publication authority to the importer. Upgrades preserve existing pinned versions and use this same boundary; entry migrations belong to the atomic typed proposal service.

## Risks / Trade-offs

Partial deployment may expose incomplete semantics. Keep new operations disabled or return explicit capability diagnostics until prerequisites are available. Authorization, crash recovery, and compatibility require real integration checks; mocked tests alone do not satisfy the release gate.

## Migration Plan

Land foundations with new behavior disabled. Preserve existing data and index encodings, use explicit versioned migration when accepted data changes, and rebuild only derived indexes. Roll back feature enablement without deleting retained sources, accepted snapshots, or proposal history. Follow the umbrella purge contract for any explicit erasure.

## Verification

Exercise this slice's scenarios with deterministic failure and authorization cases where applicable. Record relevant formatting, lint, tests, and strict OpenSpec validation. For app or Hermes flows use isolated real-server verification with disposable data and test principals. Integrated feature activation requires `verify-curated-hermes-release`; this slice does not independently claim full release readiness.
