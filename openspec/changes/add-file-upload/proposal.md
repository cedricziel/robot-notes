## Why

The vault has no way to store anything but notes. A user who wants to keep a screenshot, PDF, or reference file alongside their notes — the way Obsidian and every other note-taking tool treats attachments — has no path to do it: there is no upload endpoint, no attachment storage convention, and no client affordance. This blocks the FAB's third action ("Upload file") from being anything but a stub.

## What Changes

- New endpoint `POST /notes/attachments`: accepts a `multipart/form-data` body (a `path` field naming the target folder, a `file` field carrying the upload) and writes the file to disk alongside notes, reusing the existing filename/path sanitization from `note_path.dart`. Rejects a request over a configured max size (default 25 MiB) with `413`, and a name collision with `409` — no silent overwrite, no auto-renaming, matching how a colliding note title/path already behaves.
- New endpoint `GET /notes/attachments/{path}`: streams the raw bytes back with a content-type derived from the file extension, so an uploaded file is retrievable, not a write-only black hole.
- Flutter: the FAB's "Upload file" action opens the platform file picker (`file_picker` package, new dependency), uploads the chosen file to the currently selected folder, and shows a snackbar with the result (success naming the stored filename, or the server's error message on failure) — matching the existing note/folder FAB actions' error-handling convention.
- Server: a `maxUploadSizeBytes` config setting (`--max-upload-size-bytes` / `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES`), defaulting to 25 MiB.
- New MCP tool `upload_file`, mirroring `POST /notes/attachments`: content travels as base64 in the JSON-RPC payload (the same encoding MCP already uses for binary tool content elsewhere), decoded server-side and run through the identical size/collision/sanitization path as the REST endpoint — an agent gets the same upload capability a human gets from the FAB, not a second-class one.

## Capabilities

### New Capabilities

- `attachments`: upload/download of non-note files into the vault's folder structure — the request/response contract, size/collision handling, and content-type resolution for `POST` and `GET /notes/attachments`.

### Modified Capabilities

- `notes-storage`: the filesystem now holds a third kind of on-disk artifact (alongside note `.md` files and empty-folder `.folder` markers) — attachment files, excluded from every note-shaped scan the same way markers already are.
- `flutter-client`: the FAB gains a working "Upload file" action (previously out of scope for `add-empty-folder-creation`, which only wired up "New note" and "New folder").
- `mcp-server`: adds the `upload_file` tool to the catalog (nine tools → ten, or ten → eleven once `add-empty-folder-creation`'s `create_folder` has landed).

## Impact

Server: new route `server/routes/notes/attachments/index.dart` (or similar dart_frog file-route layout) reusing `context.request.formData()` (dart_frog's built-in multipart parser — no new server dependency), `note_path.dart`'s sanitization, and `Storage`'s existing atomic-write helpers. `config.dart` gains the size-limit setting. `server/lib/src/mcp/tools.dart` gains the `upload_file` tool, delegating to the same underlying attachment-write helper the REST route uses. Flutter: `api_client.dart` gains an `uploadFile` method, `notes_list_screen.dart`'s FAB menu gains a third item, `app_router.dart` wires it to a file-picker flow, `pubspec.yaml` gains `file_picker`.

## Non-goals

- No in-app attachment browser, listing, or delete UI — this proposal is upload + retrieval only, exactly as `add-empty-folder-creation` was creation-only for folders.
- No inline rendering of uploaded images/files inside the note editor or viewer — a note that wants to reference an attachment links to it manually; automatic embedding is a follow-up.
- No MCP tool for _downloading_ an attachment's bytes back through JSON-RPC in this pass — `GET /notes/attachments/{path}` covers retrieval for any client that can make an authenticated HTTP request (including an agent), so a base64-return tool is a follow-up if a text-only MCP client turns out to need it.
- No virus/content scanning, no thumbnailing, no image transformation.
