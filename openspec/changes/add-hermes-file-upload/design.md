## Context

`POST /notes/files` accepts `multipart/form-data` with a `path` folder field and a `file` part, returns `201 {path, filename, size, content_type}`, and rejects collisions (`409 path_conflict`), oversize bodies (`413 payload_too_large`), `.md` canonical-note uploads (`422 canonical_note_upload_forbidden`), and invalid paths (`400`). The provider runs inside the Hermes process, so a local path refers to the Hermes host.

## Goals / Non-Goals

**Goals:** one tool call per upload; zero file bytes in model context; a confined, explicit set of readable directories; no change for installs that don't opt in.

**Non-Goals:** see proposal.

## Decisions

### One direct multipart call, not the MCP two-phase flow

The provider holds a real HTTP client and the bytes are local, which is exactly the case the server's direct route exists for. Two-phase upload would add two model-visible tool calls and a token round trip for no benefit.

### Context budget

- The schema is registered only when `upload_roots` is non-empty, so sessions that never upload pay no schema tokens.
- Arguments carry a path, never content. Results carry only server metadata (no echo of the local path, no content preview).
- Errors use the existing compact `{error, code, details}` shape; confinement failures name the rule, not the directory listing.
- The system-prompt tool list gains one line, only when the tool is registered.

### Root confinement in `uploads.py`

`resolve_upload_source(local_path, roots)`:
1. Require an absolute path after `~` expansion (a relative path would resolve against an unpredictable process cwd).
2. `Path.resolve(strict=True)` — follows symlinks and collapses `..`, so a link inside a root that points outside it is rejected.
3. Require the resolved path to equal or lie under one resolved root, and to be a regular file.
4. Apply Hermes' `agent.file_safety.get_read_block_error` when importable (via `_hermes_compat`); the fallback is a no-op because roots already confine reads.

The file is opened by walking the resolved path from `/` one component at a time with `dir_fd` and `O_NOFOLLOW`, then checked with `fstat` to be regular. The resolved path has no symlinks, so a directory swapped for a link after the check (the root included) fails the open. Hosts without `dir_fd` support refuse uploads (`upload_unsupported`) instead of falling back to a path-based open.

Alternatives considered: allowing any path (rejected: one prompt injection away from sending `~/.ssh` to the server); reusing Hermes' denylist alone (rejected: a denylist cannot enumerate every secret on a host).

### Config

`upload_roots: list[str]` in `robot_notes.json`, default `[]`. Each entry must be an absolute path string; entries are kept as written and resolved at call time so a root created after startup still works. Persisted by `save()` only when non-empty.

### Write gating and timeouts

The tool joins `WRITE_TOOL_NAMES`. The upload request uses a longer timeout (120 s) than the 10 s note-write timeout, since bodies can approach the server limit.

## Risks / Trade-offs

- [A root containing secrets] → documented: roots should be dedicated export/output folders, not `$HOME`.
- [Large file stalls a turn] → bounded by the server's size limit and the 120 s timeout.
- [Curated or restricted folders] → the server enforces folder permissions; the plugin surfaces its denial.
