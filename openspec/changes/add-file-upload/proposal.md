## Why

The vault has no way to store anything but notes. A user who wants to keep a screenshot, PDF, or reference file alongside their notes — the way Obsidian and every other note-taking tool treats attachments — has no path to do it. This blocks the FAB's third action ("Upload file") from being anything but a stub, and blocks an MCP-driven agent from placing a file into the vault at all.

This is a revision of the original `add-file-upload` proposal (its first three tasks — `maxUploadSizeBytes` config, the write helper, and their tests — already merged and are kept as-is). Two problems surfaced with the original design before the rest landed:

1. **The `upload_file` MCP tool carried the file as base64 in its JSON-RPC arguments.** Base64 inflates the payload ~33%, and — more importantly — the entire file's bytes sit in the calling agent's context window and get logged/traced as a tool call. Fine for a byte or two; wrong for anything a person would actually call a "file."
2. **Uploaded files lived in a separate `attachments` namespace**, retrievable only if the caller already knew the exact path. A folder holding only files (no notes) didn't show up when browsing — files were effectively a write-only side channel, not a real citizen of the vault's folder structure.

## What Changes

- **Two-phase upload for MCP/agent callers**, replacing the single-call `upload_file(content_base64)` tool:
  1. `request_upload(path, filename, size_bytes?)` reserves a short-lived, single-use upload slot and returns `{ upload_url, token, expires_at }` — a tiny JSON-RPC call, no bytes.
  2. The caller (or whatever on its side actually holds the bytes — a sandboxed `curl`, the agent's host) `PUT`s the raw file to `upload_url` (`/notes/file-uploads/{token}`), authenticated by token possession alone (a true presigned-URL-style transfer, no bearer key needed) — this is the only step that ever touches the file's actual bytes, and it never goes through the LLM's context.
  3. `finalize_upload(token)` places the staged bytes into the vault (sanitization, collision check, atomic write — the same path a direct upload already goes through) and returns `{ path, filename, size, content_type }`.
- **Files are first-class vault entries, not a walled-off "attachments" concept.** A folder holding only uploaded files (no notes, no empty-folder marker) now appears in `GET /notes/tree` (with a `file_count` alongside `note_count`), and a new `GET /notes/files?path=` lists a folder's files directly, the same way `GET /notes` lists its notes.
- **Direct multipart upload stays for real HTTP clients.** `POST /notes/files` (renamed from `/notes/attachments`) is unchanged in spirit — the Flutter app already has real bytes and a real HTTP client, so a one-shot multipart POST has no context-bloat problem and doesn't need the two-phase dance. `GET /notes/files/{path}` (renamed from `/notes/attachments/{path}`) retrieves a file's bytes, unchanged.
- Flutter: the FAB's "Upload file" action is unaffected in behavior — it still opens the file picker and posts to the (renamed) direct-upload route.
- Server: `maxUploadSizeBytes` config (already merged) governs both upload paths.

## Capabilities

### New Capabilities

- `vault-files`: files as first-class, browsable vault entries — direct upload/retrieval/listing (`POST`/`GET` `/notes/files`), and the two-phase upload-session flow (`PUT /notes/file-uploads/{token}`) that backs the MCP tools. Supersedes the original `attachments` capability (never released — this change replaces it in place before archival).

### Modified Capabilities

- `notes-storage`: files are indexed the same way empty-folder markers are (a lightweight, non-note-shaped tracked set), so they contribute to folder discoverability without being treated as notes by any note-shaped scan or operation.
- `flutter-client`: unchanged behaviorally from the original proposal — the FAB's "Upload file" action, now pointed at the renamed route.
- `mcp-server`: `request_upload` and `finalize_upload` join the catalog; `upload_file` (from the original proposal) never merged and is no longer part of this change — the catalog grows from today's ten tools to twelve.

## Impact

Server: `server/lib/src/attachments.dart` → `server/lib/src/vault_files.dart` (renamed `FileStore`, was `AttachmentStore`), plus a new `server/lib/src/upload_sessions.dart` (in-memory `UploadSessionStore`: token mint, expiry, staged-bytes-to-final-vault handoff). Routes move from `server/routes/notes/attachments/` to `server/routes/notes/files/`, plus a new `server/routes/notes/file-uploads/[token].dart`. `Storage`/`MetaIndex` gain file-awareness for tree/listing. `server/lib/src/mcp/tools.dart`: `upload_file` removed, `request_upload` and `finalize_upload` added. Flutter: `api_client.dart`'s `uploadFile` target path renamed; no behavioral change.

## Non-goals

- No in-app file browser UI showing files mixed into the notes list (this proposal makes files _server-discoverable_; rendering them in the Flutter UI is a follow-up).
- No inline rendering of uploaded images/files inside the note editor or viewer.
- No resumable/chunked upload (a dropped connection mid-PUT means starting over with a fresh `request_upload`).
- No virus/content scanning, no thumbnailing, no image transformation.
- No iOS/macOS share extension, no macOS Finder drag-and-drop upload — both are separate, platform-specific proposals that build on top of this once it lands.
