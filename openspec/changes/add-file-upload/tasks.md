## 1. Config: max upload size

- [x] 1.1–1.5 Already merged (`Config.maxUploadSizeBytes`, CLI/env resolution, tests). No further work.

## 2. Server: rename the write helper (AttachmentStore → FileStore)

- [ ] 2.1 Rename `server/lib/src/attachments.dart` → `server/lib/src/vault_files.dart`: `AttachmentStore` → `FileStore`, `AttachmentWriteResult` → `FileWriteResult`, `AttachmentCollisionException` → `FileCollisionException`, `AttachmentTooLargeException` → `FileTooLargeException`. No behavior change — update every call site and test file accordingly.
- [ ] 2.2 Run the full server test suite green (this is a pure rename; nothing new to test yet).
- [ ] 2.3 Commit: `refactor(server): rename AttachmentStore to FileStore`

## 3. Server: index files for folder discoverability

- [ ] 3.1 Write a failing test: `Storage._scanAll()` (via a public-enough seam — e.g. a new `Storage.filesIn(path)` after constructing a `Storage` over a temp dir with a plain non-`.md` file placed directly on disk) discovers a file placed directly on disk, independent of any upload path
- [ ] 3.2 Write a failing test: a file ending in `.tmp` is excluded from the file index
- [ ] 3.3 Write a failing test: `Storage.filesIn(path)` returns only the direct children of `path`, not files in subfolders
- [ ] 3.4 Write a failing test: a folder holding only a file (no note, no empty-folder marker) is included in `GET /notes/tree`'s response with `file_count >= 1`
- [ ] 3.5 Write a failing test: a folder holding a note, an empty-folder marker, and a file all continues to report the correct `note_count` and `file_count` independently
- [ ] 3.6 Implement: extend `Storage._scanAll()` to track non-`.md`, non-marker, non-`.tmp` files (relative path, size, modified time); add `Storage.filesIn(String folderPath)`; extend `GET /notes/tree`'s handler and `TreeFolder`'s wire shape with `file_count`; run 3.1–3.5 green
- [ ] 3.7 Commit: `feat(server): index uploaded files for folder-tree discoverability`

## 4. Server: rename routes and add GET /notes/files listing

- [ ] 4.1 Move `server/routes/notes/attachments/index.dart` → `server/routes/notes/files/index.dart`; add `GET` handling for a bare `/notes/files?path=` request there (listing) alongside the existing `POST` (direct upload), both updated for the `FileStore` rename
- [ ] 4.2 Move `server/routes/notes/attachments/[...path].dart` → `server/routes/notes/files/[...path].dart` (retrieval), updated for the rename
- [ ] 4.3 Write a failing route test: `GET /notes/files?path=Ideas` returns only `Ideas`'s direct files as `{ items: [...] }`, excluding subfolder files and notes
- [ ] 4.4 Write a failing route test: `GET /notes/files` (no `path`) lists the vault root's direct files
- [ ] 4.5 Move and update the existing `POST`/`GET` route tests (path collision, oversized upload, retrieval, 404) to the new paths; confirm they still pass unchanged in behavior
- [ ] 4.6 Implement 4.3–4.4; run all of 4.3–4.5 green
- [ ] 4.7 Commit: `feat(server): rename attachment routes to /notes/files and add folder listing`

## 5. Server: upload-session store and the PUT completion route

- [ ] 5.1 Write a failing test: `UploadSessionStore.reserve(path, filename, maxBytes)` returns a token, an `expiresAt` in the future, and the session is retrievable by that token
- [ ] 5.2 Write a failing test: `UploadSessionStore.complete(token, bytes, contentType)` streams bytes to a staging file under a directory outside `contentDir`, bounded by the session's `maxBytes`, and marks the session `uploaded` with the final size
- [ ] 5.3 Write a failing test: completing an already-`uploaded` or unknown/expired token throws (single-use, and expired-and-thus-gone)
- [ ] 5.4 Write a failing test: exceeding `maxBytes` during `complete` deletes any partial staging file and leaves the session usable for a fresh attempt (or is deleted outright — pick whichever the implementation makes simplest; the observable contract is just "no partial file survives")
- [ ] 5.5 Write a failing test: an expired session (`expiresAt` in the past) behaves as not-found for both `complete` and `finalize`
- [ ] 5.6 Write a failing test: `UploadSessionStore.finalize(token, fileStore)` reads the staged bytes and calls `FileStore.write` with the session's `path`/`filename`/`contentType`/`maxBytes`, deletes the session and staging file on success, and propagates `FileCollisionException` untouched (also cleaning up the session/staging file) on a finalize-time collision
- [ ] 5.7 Implement `server/lib/src/upload_sessions.dart` (`UploadSession`, `UploadSessionStore`, staging directory under `<dataDir>/uploads/`, periodic expiry sweep); run 5.1–5.6 green
- [ ] 5.8 Write a failing route test: `PUT /notes/files/uploads/{token}` with no `Authorization` header, valid token, and a body within the size limit responds `200` with `{ token, size, content_type, expires_at }` and the file is completable via `finalize_upload`
- [ ] 5.9 Write a failing route test: `PUT` with a missing/expired/already-completed token responds `404`
- [ ] 5.10 Write a failing route test: `PUT` exceeding the configured max size responds `413` and leaves no staged file
- [ ] 5.11 Implement `server/routes/notes/files/uploads/[token].dart`, wiring it to skip the normal bearer-auth middleware requirement (token-only auth, per design.md); run 5.8–5.10 green
- [ ] 5.12 Commit: `feat(server): add upload-session store and PUT /notes/files/uploads/{token}`

## 6. Server: request_upload and finalize_upload MCP tools

- [ ] 6.1 Write a failing test: `tools/list` includes `request_upload` (`inputSchema.required == ["path", "filename"]`) and `finalize_upload` (`inputSchema.required == ["token"]`); update every hard-coded catalog-size assertion (nine→ten→twelve, not eleven — `upload_file` never merged)
- [ ] 6.2 Write a failing test: `request_upload` with a small file returns `structuredContent` containing `token`, `upload_url`, `expires_at`
- [ ] 6.3 Write a failing test: `request_upload` with `size_bytes` over the configured limit returns `isError: true`, `structuredContent.error == "payload_too_large"`, and reserves no session
- [ ] 6.4 Write a failing test: `finalize_upload` after a real `PUT` to the session's `upload_url` returns `structuredContent == {path, filename, size, content_type}` matching the REST shape, and the file is retrievable via `GET /notes/files/{path}`
- [ ] 6.5 Write a failing test: `finalize_upload` with a token that was never `PUT`-completed (or is unknown) returns `isError: true`, `structuredContent.error == "validation_failed"`
- [ ] 6.6 Write a failing test: `finalize_upload` targeting a path that collides at finalize time returns `isError: true`, `structuredContent.error == "path_conflict"`
- [ ] 6.7 Implement both tool definitions and handlers in `server/lib/src/mcp/tools.dart`, delegating to `UploadSessionStore`/`FileStore`; run 6.1–6.6 green
- [ ] 6.8 Commit: `feat(server): add request_upload and finalize_upload MCP tools`

## 7. Flutter: point the client and FAB at the renamed route

- [ ] 7.1 Write a failing test: `RobotNotesClient.uploadFile` now posts to `/notes/files` (was `/notes/attachments`)
- [ ] 7.2 Implement the rename; run the app test suite green (the FAB wiring from the prior implementation attempt needs no further change beyond this URL)
- [ ] 7.3 Commit: `fix(app): point uploadFile at the renamed /notes/files route`

## 8. Docs and end-to-end check

- [ ] 8.1 Run the full server and app test suites; fix any regressions
- [ ] 8.2 Update `server/STORAGE.md` to document the file index, the `<dataDir>/uploads/` staging directory, and the two upload paths
- [ ] 8.3 Update `server/API.md` to document `POST /notes/files`, `GET /notes/files/{path}`, `GET /notes/files?path=`, `PUT /notes/files/uploads/{token}`, and the `request_upload`/`finalize_upload` MCP tools
- [ ] 8.4 Manually verify against a running server + app: upload via the FAB, confirm the folder shows up in the tree and its file is listed via `GET /notes/files?path=`; call `request_upload` → `curl -T` → `finalize_upload` directly over `/mcp` and confirm the same file lands, is retrievable, and a same-path re-`request_upload`+finalize collides with `409`/`path_conflict`
- [ ] 8.5 Commit: `docs(server): document vault-files, upload sessions, and the two upload paths`

## Definition of Done

- All tasks above checked off, each with its own green test run and its own commit
- `openspec validate add-file-upload --strict` passes
- Full server (`dart test`) and Flutter (`flutter test`) suites pass
- A file uploaded via either path survives a server restart, remains retrievable, and shows up when browsing its folder
- No `TODO`/`FIXME` left from this change in touched files
