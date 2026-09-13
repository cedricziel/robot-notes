## Context

See `proposal.md` - Why. Hermes Agent's `MemoryProvider` contract (`agent/memory_provider.py` in `NousResearch/hermes-agent`) is an external ABC we must implement, not something we design: `name`, `is_available()`, `initialize()`, `get_tool_schemas()`/`handle_tool_call()` are abstract; `system_prompt_block()`, `prefetch()`/`queue_prefetch()`, `sync_turn()`, `on_session_end()`, `on_memory_write()`, `get_config_schema()`/`save_config()`, `backup_paths()` are optional overrides we opt into per `specs/hermes-memory-plugin/spec.md`. A plugin directory is `<name>/__init__.py` + `plugin.yaml` (+ optional `config_schema.py`, `README.md`); Hermes discovers it from `$HERMES_HOME/plugins/<name>/`, a pip entry point, or its own bundled `plugins/memory/<name>/` — we target the first (no upstream PR).

robot-notes itself already exposes everything the plugin needs as a plain bearer-key REST API (`openspec/specs/notes-api/spec.md`, `openspec/specs/auth/spec.md`): `GET/POST/PUT/DELETE /notes`, `GET /search`, optimistic concurrency via `version`/`If-Match`, and `X-Actor` for attribution. The plugin is a pure client of that existing, unchanged surface.

This repo is a Dart pub workspace (`shared/`, `server/`, `app/`) with Dart-specific tooling (`dart_pre_commit`, `make test`, etc.). The plugin is Python, so it needs its own isolated toolchain that the Dart workspace and its pre-commit hook never touch.

## Goals / Non-Goals

**Goals:**

- Implement the `MemoryProvider` surface described in the spec, as a directory that can be copied or symlinked straight into `$HERMES_HOME/plugins/robot_notes/`.
- Keep the plugin a thin REST client: no local database, no offline queue, no MCP client.
- Keep writes sparse and predictable (session-end, explicit tool calls, built-in-memory mirror only), per spec.
- Isolate the Python toolchain from the Dart workspace: its own dependency manifest, its own test runner, its own CI job.

**Non-Goals:**

- No local durability/write-behind queue (unlike `retaindb`'s SQLite queue) — if robot-notes is unreachable at write time, the write is retried a bounded number of times and then dropped with a logged warning; v1 accepts best-effort delivery for session-end and memory-mirror writes.
- No packaging for PyPI or a pip entry point in this change — distribution is "copy this directory," matching the proposal's non-goals.
- No changes to robot-notes' server, MCP endpoint, or auth model.

## Decisions

**Directory layout — `hermes-plugin/robot_notes/{__init__.py,plugin.yaml,config_schema.py,README.md}` at repo root.**
Mirrors the exact shape Hermes expects for a plugin directory, so "install" is a copy/symlink with no repackaging step. Alternative considered: nest under `tool/` or `integrations/` — rejected because Hermes' loader expects the plugin's own name as the directory name (`robot_notes/`), and burying it under another directory only adds a path segment users have to know to strip when copying.

**Transport: direct REST client (`httpx`), not an embedded MCP client.**
robot-notes' REST API and its `/mcp` tool catalog are two facades over the same operations; talking REST directly avoids implementing JSON-RPC framing, `initialize`/`tools/list` handshakes, and protocol-version negotiation inside a memory plugin that only ever needs a handful of fixed calls. `httpx` over `requests` because it supports both sync and an async client from one dependency, and other bundled Hermes providers (e.g. `retaindb`) already lean sync-with-background-thread rather than asyncio — we'll follow that same pattern (a small background thread for recall prefetch) rather than pull in an event loop.

**No local write-behind queue.**
`retaindb` buffers writes in SQLite for durability across restarts/offline periods. We skip this for v1: writes are already infrequent (session-end, explicit tool call, memory mirror), so a bounded synchronous retry (3 attempts, matching robot-notes' own `append_to_note` retry count) with a logged failure is enough. Revisit if session-end summaries are found to be silently dropped in practice.

**Session summary note identity: path `Hermes/Sessions/`, title = session id.**
Filing every session note under one fixed folder keeps the mapping mechanical (spec: "fixed, predictable location keyed by the session identifier") and lets a human browse all Hermes sessions in one place in the robot-notes app. The plugin looks the note up by title within that folder before creating one, so a resumed session updates in place (`update_note`/`append_to_note` with the note's current `version`) instead of duplicating.

**Built-in memory mirror: two fixed notes, `Hermes/Memory.md` and `Hermes/User.md`.**
`on_memory_write(target=...)` distinguishes `memory` vs `user`; mapping each to its own fixed note (rather than one combined note) keeps the mirror structurally parallel to Hermes' own `MEMORY.md`/`USER.md` split, and keeps `add`/`replace`/`remove` operations scoped to the right note without parsing sections out of a shared file. `replace`/`remove` re-read the note's current content, apply the edit, and write back under its current version; `add` uses the same append semantics as the `remember` tool.

**Config storage: flat JSON at `$HERMES_HOME/robot_notes.json` for non-secret fields; API key via Hermes' secret store / env var (`ROBOT_NOTES_API_KEY`).**
Matches the `STORAGE_FLAT_JSON` pattern most bundled providers use (vs. Honcho's bespoke host-block format, which doesn't apply since we have no multi-peer concept) and keeps the secret out of a plain file per spec.

**Testing: pytest, isolated under `hermes-plugin/`.**
The repo's TDD convention (`README.md` - Conventions) applies per-language, not per-toolchain-identical: `hermes-plugin/` gets its own `pyproject.toml` (or `requirements-dev.txt`) and `pytest.ini`/config, run via `make test-hermes-plugin` (new Makefile target) so `make test` can optionally include it without every Dart contributor needing Python installed for the main suites. CI adds a job scoped to path changes under `hermes-plugin/`.

## Risks / Trade-offs

- **Best-effort writes** → a session-end summary or memory mirror can be lost if robot-notes is down at exactly that moment, with no queue to retry later. Mitigation: bounded retry + a warning surfaced through Hermes' own logging, and this is called out as an explicit v1 non-goal so it's a known, not silent, limitation.
- **Two memory systems can drift** (Hermes' `MEMORY.md`/`USER.md` vs. the mirrored notes) if a robot-notes note is edited directly by a human or another agent — the mirror is one-directional (built-in → robot-notes only). Mitigation: none in v1; the plugin's `system_prompt_block()` should say the notes are the shared, authoritative copy so users know to edit there.
- **New Python toolchain in an otherwise all-Dart repo** → risk of bit-rot if no one runs its tests. Mitigation: dedicated CI job gated on path changes, so it can't silently stop running without a visible CI signal.

## Open Questions

- Whether `hermes-plugin/` should eventually become its own pip-installable package (for entry-point discovery) is left for a future change once the copy/symlink workflow has been used in practice.
