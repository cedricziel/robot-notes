## Context

PR #387 merged the umbrella contract in `add-curated-knowledge`. Existing revision retention, stable block identities, scoped credentials, Hermes identity scope, and durable memory retries are available foundations. Planning completion is not runtime completion.

## Goals / Non-Goals

**Goals:** Implement the requirements in this change's delta spec with one bounded service contract and focused adapter changes.

**Non-Goals:** Implement sibling slices, alter ordinary note behavior incidentally, or enable the full feature before the release gate passes.

## Decisions

Implement a durable server scheduler and worker for explicitly enabled source scopes. Pin source, originating identity, extractor configuration and type versions. Recheck access and eligibility, resolve entities conservatively and submit proposals through the shared service without acceptance authority.

Reuse the umbrella document formats and service contracts rather than introduce parallel stores or adapter-specific semantics. Stage externally visible functionality behind explicit enablement so each foundation can land safely. Reuse existing history and credential primitives; add regression checks instead of rebuilding completed foundations.

### Conversation trigger configuration

Capture and extraction require separate explicit enablement for the selected vault
and source scope. Conversation extraction accepts `session_end`, `completed_turn`,
or `both`; enabled scopes default to `session_end`. Trigger changes affect future
events and do not replay historical conversations automatically.

Use Hermes `sync_turn()` for completed-turn observations and `on_session_end()`
for session-boundary observations. Neither callback identifies task completion.
Callbacks enqueue bounded capture work without waiting for model extraction. An
eligible observation must have a durably acknowledged immutable source revision
before the server creates its extraction job. Do not extract from mutable mirror
notes or treat a saved transcript as consent to capture sources. Restricted
subagent, cron, and flush provider contexts do not emit extraction observations.

Hermes supplies static instructions through `system_prompt_block()` but exposes no
task-completion or before-final memory-provider callback. The immediate agent
reminder uses that prompt surface independently of background extraction. Prompt
injection does not guarantee that the agent submits a proposal.

### Incremental extraction and duplicate suppression

Pin each job to its source revision, supplied conversation identity, originating
principal and scope, extractor configuration, type versions, and observed trigger.
Use stable observation and job keys for delivery retries. Persist consumed source
coordinates and candidate fingerprints within the same conversation, scope, and
extractor generation. In `both` mode, session-end processing reviews uncovered
passages and additional context without resubmitting unchanged turn candidates.
Changed claims retain evidence lineage and become correction proposals rather
than silently replacing accepted text. Explicit re-extraction uses a new generation.

### Shared read → compare → classify → propose workflow

Use the same workflow as the bundled plugin skill:

1. Read the immutable source revision and locate supporting passages. Verify exact
   values and quotations, and distinguish source assertions from derived inferences.
2. Compare findings with readable accepted knowledge and authorized ongoing
   proposals using concepts, entity names, and aliases. Inspect related claims
   affected by new evidence. Pending candidates are comparison targets, not truth.
3. Classify each finding as `new`, `update`, `disputed`, or `no_material` with a
   reason. The first three may combine; `no_material` is exclusive. Persist the
   disposition in job diagnostics and include it with each retained candidate.
4. Propose focused changes organized around durable concepts or entities. Preserve
   exact source revision and passage locators. Compatible additions update existing
   topics. Corrections and conflicts preserve prior claim lineage and remain explicit
   review decisions. List related readable targets requiring review without silently
   modifying their accepted content.

Skip temporary details, unsupported speculation, and unchanged duplicates.
`no_material` completes successfully without a proposal. A disputed finding retains
both claims and their evidence without selecting a winner automatically. Uncertain
entity matches remain diagnostics rather than forced merges. Every candidate covers
one durable fact, decision with rationale, procedure, or correction. Preserve source
material unchanged. Do not treat a generated answer as independent evidence.

The workflow adapts the incremental source-grounded principles in
[Karpathy's LLM Wiki blueprint](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
and the [community LLM-wiki skill](https://github.com/Astro-Han/karpathy-llm-wiki/blob/main/SKILL.md).
Robot Notes retains its source store, permissions, proposal APIs, and review boundary.

Treat source text as untrusted data. Enforce configured input, candidate-count,
model-time, and retry bounds. Coalesce queued completed-turn work while retaining
all uncovered source coordinates. Persist progress before releasing a lease.
Expose job health and limit diagnostics without source content. Denied or
unsupported proposal operations never fall back to ordinary accepted writes.

All extracted text requires human review. Verified source attachments to unchanged
accepted text remain governed by the existing separate acceptance policy.

Dependencies: `add-knowledge-agent-tools`, `add-versioned-knowledge-sources`. Dependencies must provide their verified service contract before this slice enables its dependent operations. Existing issue alignment: No new issue filed. No additional issues are filed by this planning change.

Implement tests before behavior in each task pair. Keep conventional commits coherent and use focused PRs, preferably below 500 lines; split a slice into service, adapter, or verification PRs when needed. Dependencies describe semantic order, not a requirement to build a single long-lived branch stack.

## Risks / Trade-offs

Partial deployment may expose incomplete semantics. Keep new operations disabled or return explicit capability diagnostics until prerequisites are available. Authorization, crash recovery, and compatibility require real integration checks; mocked tests alone do not satisfy the release gate.

Completed-turn mode reduces delay but adds model cost and proposals from partial
conversations. Session-end mode supplies more context but can wait indefinitely
for a long-lived session. `both` requires durable coverage tracking to avoid
repeated candidates. None of these triggers establishes task completion.

## Migration Plan

Land foundations with new behavior disabled. Preserve existing data and index encodings, use explicit versioned migration when accepted data changes, and rebuild only derived indexes. Roll back feature enablement without deleting retained sources, accepted snapshots, or proposal history. Follow the umbrella purge contract for any explicit erasure.

## Verification

Exercise this slice's scenarios with deterministic failure and authorization cases where applicable. Record relevant formatting, lint, tests, and strict OpenSpec validation. For app or Hermes flows use isolated real-server verification with disposable data and test principals. Integrated feature activation requires `verify-curated-hermes-release`; this slice does not independently claim full release readiness.
