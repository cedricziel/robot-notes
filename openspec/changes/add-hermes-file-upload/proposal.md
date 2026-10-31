## Why

The Hermes memory plugin cannot put a file into the vault. The server already accepts direct multipart uploads (`POST /notes/files`), but the plugin only exposes note tools, so a Hermes agent that produces a screenshot, PDF, or export has no native way to file it next to the notes it writes. The MCP two-phase upload (`request_upload` → `PUT` → `finalize_upload`) works, but it costs three model-visible steps and needs a separate HTTP transfer the agent has to orchestrate.

Every tool schema, argument, and result is part of the model's context. A file tool must not make the context pay for the file: no bytes or base64 in arguments, no file content in results, and no schema tokens in sessions that never upload.

## What Changes

- Add one native tool, `robotnotes_upload_file(local_path, path?, filename?)`. The provider opens the named local file on the Hermes host and streams it to `POST /notes/files` with the existing bearer credential. The model only ever sees the path it passed and a compact result: `{path, filename, size, content_type}`.
- Uploads are opt-in. A new `upload_roots` setting lists absolute directories the tool may read from. With no roots configured, the tool is neither advertised nor callable, and nothing changes for existing installs.
- The provider resolves symlinks and `..` before checking the target lies under a root, accepts only regular files, and also honors Hermes' own read denylist (credential stores, `.env` files) when the host provides it.
- The tool counts as a write: read-only contexts (subagents, cron, flush) refuse it like the other write tools.
- Server errors map to the existing tool error shape: `path_conflict` (name taken, no overwrite), `payload_too_large`, `canonical_note_upload_forbidden`, permission denial.

## Capabilities

### New Capabilities

- `hermes-file-upload`: native, opt-in, root-confined local file upload from the Hermes memory provider into the vault.

### Modified Capabilities

None. The server's `vault-files` contract is used as-is.

## Impact

`hermes-plugin/robot_notes/`: `config.py` (`upload_roots`), `client.py` (`upload_file`), `tools.py` (schema + handler entry), `__init__.py` (handler, write gating, schema filtering, prompt line), a new `uploads.py` for path confinement. Docs: plugin `README.md`, `TOOL_INVENTORY.md`. No server, app, or MCP changes.

## Non-goals

- No upload of bytes supplied by the model (base64 or inline text).
- No upload from the user's device when it differs from the Hermes host.
- No overwrite or auto-rename on name collision; the caller picks a new `filename`.
- No download, listing, or deletion tools for vault files.
- No client-side size limit; the server's `maxUploadSizeBytes` stays authoritative.
- No setup-wizard prompt for `upload_roots`; it is set in `robot_notes.json`.
