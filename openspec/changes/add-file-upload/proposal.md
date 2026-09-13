## Why

The vault has no way to store anything but notes. A user who wants to keep a screenshot, PDF, or reference file alongside their notes — the way Obsidian and every other note-taking tool treats attachments — has no path to do it: there is no upload endpoint, no attachment storage convention, and no client affordance. This blocks the FAB's third action ("Upload file") from being anything but a stub.

## What Changes

- New endpoint `POST /notes/attachments`: accepts a `multipart/form-data` body (a `path` field naming the target folder, a `file` field carrying the upload) and writes the file to disk alongside notes, reusing the existing filename/path sanitization from `note_path.dart`. Rejects a request over a configured max size (default 25 MiB) with `413`, and a name collision with `409` — no silent overwrite, no auto-renaming, matching how a colliding note title/path already behaves.
- New endpoint `GET /notes/attachments/{path}`: streams the raw bytes back with a content-type derived from the file extension, so an uploaded file is retrievable, not a write-only black hole.
- Flutter: the FAB's "Upload file" action opens the platform file picker (`file_picker` package, new dependency), uploads the chosen file to the currently selected folder, and shows a snackbar with the result (success naming the stored filename, or the server's error message on failure) — matching the existing note/folder FAB actions' error-handling convention.
- Server: a `maxUploadSizeBytes` config setting (`--max-upload-size-bytes` / `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES`), defaulting to 25 MiB.

## Capabilities

### New Capabilities

- `attachments`: upload/download of non-note files into the vault's folder structure — the request/response contract, size/collision handling, and content-type resolution for `POST` and `GET /notes/attachments`.

### Modified Capabilities

- `notes-storage`: the filesystem now holds a third kind of on-disk artifact (alongside note `.md` files and empty-folder `.folder` markers) — attachment files, excluded from every note-shaped scan the same way markers already are.
- `flutter-client`: the FAB gains a working "Upload file" action (previously out of scope for `add-empty-folder-creation`, which only wired up "New note" and "New folder").

## Impact

Server: new route `server/routes/notes/attachments/index.dart` (or similar dart_frog file-route layout) reusing `context.request.formData()` (dart_frog's built-in multipart parser — no new server dependency), `note_path.dart`'s sanitization, and `Storage`'s existing atomic-write helpers. `config.dart` gains the size-limit setting. Flutter: `api_client.dart` gains an `uploadFile` method, `notes_list_screen.dart`'s FAB menu gains a third item, `app_router.dart` wires it to a file-picker flow, `pubspec.yaml` gains `file_picker`.

## Non-goals

- No in-app attachment browser, listing, or delete UI — this proposal is upload + retrieval only, exactly as `add-empty-folder-creation` was creation-only for folders.
- No inline rendering of uploaded images/files inside the note editor or viewer — a note that wants to reference an attachment links to it manually; automatic embedding is a follow-up.
- No MCP tool for upload in this pass — a binary upload over JSON-RPC would need base64 encoding and its own size/error semantics; agents working with notes as text don't need this yet.
- No virus/content scanning, no thumbnailing, no image transformation.
