## Why

Hermes Agent (`NousResearch/hermes-agent`) is a coding-agent CLI with a pluggable memory-provider system, but none of its bundled providers (mem0, honcho, retaindb, ...) let an agent share memory with a robot-notes workspace. Since robot-notes already exists to be "shared memory between humans and agents," a Hermes-side plugin lets any Hermes agent read and write that same shared vault instead of an isolated, provider-specific memory store.

## What Changes

- Add a new Python package at `hermes-plugin/robot_notes/` implementing Hermes Agent's `MemoryProvider` interface, distributed by copying/symlinking the directory into `$HERMES_HOME/plugins/robot_notes/` (no upstream PR to hermes-agent required).
- The plugin authenticates with robot-notes' existing static API key (`ROBOT_NOTES_API_KEY`) and calls its existing REST API (`GET/POST/PUT/DELETE /notes`, `GET /search`) directly — no MCP client, no new server-side capability.
- Recall: `prefetch()` searches the vault and injects top matches into context; `get_tool_schemas()`/`handle_tool_call()` expose `robotnotes_search`, `robotnotes_note`, `robotnotes_remember`, `robotnotes_forget` tools for the model to call explicitly.
- Persistence: writes are deliberately sparse — `on_session_end()` files a per-session summary note under a fixed folder, and `on_memory_write()` mirrors Hermes' own built-in `MEMORY.md`/`USER.md` writes into a corresponding robot-notes note. No per-turn writes.
- Config: `get_config_schema()`/`save_config()` drive `hermes memory setup` for `base_url`, `actor`; the API key stays a secret env var, per Hermes convention.
- New Python test suite (pytest) for this subpackage — the first non-Dart toolchain in the repo, isolated to `hermes-plugin/` and excluded from the Dart pub workspace.

## Capabilities

### New Capabilities

- `hermes-memory-plugin`: a Hermes Agent `MemoryProvider` plugin, shipped from this repo, that uses robot-notes' REST API as Hermes' external memory backend — covering availability/config, recall (prefetch + search tools), sparse write paths (session-end summaries, explicit tool calls, built-in-memory mirroring), and the session-to-note mapping.

### Modified Capabilities

(none — the plugin is a pure client of already-specified, already-implemented `notes-api` and `auth` behavior; no server-side requirement changes)

## Impact

- New top-level directory `hermes-plugin/` (Python), with its own `pyproject.toml`/`requirements` and pytest suite — isolated from the Dart `pubspec.yaml` workspace so `dart pub get`/`flutter` tooling never touches it.
- No changes to `server/`, `app/`, or `shared/`.
- New CI consideration: a Python lint/test job scoped to `hermes-plugin/` (details in `design.md`/`tasks.md`).
- Depends on robot-notes' existing static-API-key auth and REST endpoints; no new server-side deploy step.

## Non-goals

- No OAuth/OIDC support for the plugin in v1 — static API key only.
- No upstream contribution to `NousResearch/hermes-agent`'s bundled `plugins/memory/` — ships as an external/user plugin only.
- No per-turn memory writes (`sync_turn` stays a no-op) — only session-end summaries and explicit tool calls.
- No changes to robot-notes' server-side MCP or REST behavior.
