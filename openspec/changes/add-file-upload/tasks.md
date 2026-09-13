## 1. Config: max upload size

- [ ] 1.1 Write a failing test: `Config.fromArgs` defaults `maxUploadSizeBytes` to 26,214,400 (25 MiB) when neither `--max-upload-size-bytes` nor `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` is set
- [ ] 1.2 Write a failing test: `--max-upload-size-bytes 52428800` overrides the default
- [ ] 1.3 Write a failing test: `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` env var overrides the default when the CLI flag is absent, and the CLI flag wins when both are set
- [ ] 1.4 Implement `maxUploadSizeBytes` on `Config`, following the same CLI-then-env-then-default resolution as `lockTtlSeconds`; run 1.1–1.3 green
- [ ] 1.5 Commit: `feat(server): add a configurable max upload size setting`

## 2. Server: attachment write helper (sanitization, collision, atomic write)

- [ ] 2.1 Write a failing test: sanitizing `path: "Projects/Alpha"` + `filename: "My File.PNG"` normalizes and strips illegal characters the same way a note's path/title do (reusing `sanitizedPathSegments`/`sanitizeFilenameSegment`/`normalizeToNfc`)
- [ ] 2.2 Write a failing test: an invalid path segment (`.`, `..`, or empty-after-sanitizing) throws `InvalidPathException`, matching `Storage.createFolder`
- [ ] 2.3 Write a failing test: the resolved target collides (case/NFC-insensitively, via `collisionKey`) with an existing note file, an existing attachment, or an existing empty-folder marker — all three count as a collision and throw a dedicated conflict exception, no write attempted
- [ ] 2.4 Write a failing test: a target with no collision writes the given bytes atomically (tmp+fsync+rename, matching `Storage`'s note-write pattern) and returns `{path, filename, size, content_type}`
- [ ] 2.5 Write a failing test: writing more bytes than a configured limit aborts partway through (simulate with a small limit) and leaves no partial file at the target path
- [ ] 2.6 Write a failing test: two concurrent writes to the same new target path are serialized (reuse `Storage`'s per-target-path lock/collision-key mechanism) so exactly one succeeds and the other observes a collision, mirroring the equivalent `Storage.createFolder` race fix
- [ ] 2.7 Implement the write helper (per design.md, as a small helper alongside `Storage` — promote it to a `Storage` method instead only if that ends up simpler once written), taking a byte stream (not a buffered `List<int>`) so both the REST route and the MCP tool can feed it without double-buffering; run 2.1–2.6 green
- [ ] 2.8 Commit: `feat(server): add attachment write helper (sanitization, collision, atomic write)`

## 3. Server: POST /notes/attachments

- [ ] 3.1 Write a failing route test: posting a multipart body with `path: ""` and a small file returns `201 Created` with `{ path: "", filename, size, content_type }`, and the file exists on disk with the exact bytes sent
- [ ] 3.2 Write a failing route test: `path: "Projects/Alpha"` with intermediates that don't exist yet creates the full folder chain (same behavior as `POST /notes/tree`)
- [ ] 3.3 Write a failing route test: a filename colliding with an existing file at the target path returns `409 Conflict` and does not modify the existing file
- [ ] 3.4 Write a failing route test: a body exceeding the configured `maxUploadSizeBytes` (mock a small limit for the test) returns `413 Payload Too Large` and leaves no partial file at the target path
- [ ] 3.5 Write a failing route test: an invalid `path` segment returns `400 Bad Request`
- [ ] 3.6 Write a failing route test: a request missing the `file` field, or missing `path`, returns `400 Bad Request`
- [ ] 3.7 Implement `POST /notes/attachments` using `context.request.formData()` (dart_frog's built-in multipart parser) feeding `UploadedFile.openRead()` into the task-2 write helper; run 3.1–3.6 green
- [ ] 3.8 Commit: `feat(server): add POST /notes/attachments`

## 4. Server: GET /notes/attachments/{path}

- [ ] 4.1 Write a failing route test: requesting a previously-uploaded file's path returns `200 OK` with the original bytes and a `Content-Type` derived from the extension (e.g. `.png` → `image/png`)
- [ ] 4.2 Write a failing route test: a nested path (`Projects/Alpha/diagram.png`) resolves correctly
- [ ] 4.3 Write a failing route test: a path with no file at it returns `404 Not Found`
- [ ] 4.4 Write a failing route test: an unrecognized extension falls back to `application/octet-stream`
- [ ] 4.5 Implement `GET /notes/attachments/[...path]` as a catch-all route (per design.md), resolving content-type via the `mime` package; run 4.1–4.4 green
- [ ] 4.6 Commit: `feat(server): add GET /notes/attachments/{path} to retrieve uploads`

## 5. Server: upload_file MCP tool

- [ ] 5.1 Write a failing test: `tools/list` includes `upload_file` with `inputSchema.required == ["path", "filename", "content_base64"]`, alongside the existing catalog (update any hard-coded catalog-size assertions in existing MCP tests)
- [ ] 5.2 Write a failing test: `upload_file` with a small `content_base64` payload returns `structuredContent == {"path", "filename", "size", "content_type"}` matching the REST endpoint's shape, and the file is retrievable via `GET /notes/attachments/{path}`
- [ ] 5.3 Write a failing test: `upload_file` targeting a path that already has a file returns `isError: true` with `structuredContent.error == "path_conflict"` (reusing `kErrorPathConflict`)
- [ ] 5.4 Write a failing test: `upload_file` with a decoded payload over the configured `maxUploadSizeBytes` returns `isError: true` with `structuredContent.error == "payload_too_large"` (new error code)
- [ ] 5.5 Write a failing test: `upload_file` with `content_base64` that is not valid base64 returns `isError: true` with `structuredContent.error == "validation_failed"`
- [ ] 5.6 Implement the `upload_file` tool definition and handler in `server/lib/src/mcp/tools.dart`, delegating to the same task-2 write helper `POST /notes/attachments` uses (per design.md, no duplicated implementation) — decode base64 into bytes, check the decoded length against the limit before writing; run 5.1–5.5 green
- [ ] 5.7 Commit: `feat(server): add upload_file MCP tool`

## 6. Flutter: upload API client method

- [ ] 6.1 Write a failing test in `api_client_test.dart`: a new `uploadFile({required String path, required String filename, required List<int> bytes, String? contentType})` method POSTs a multipart request to `/notes/attachments` with the given fields and returns the decoded `{path, filename, size, content_type}`
- [ ] 6.2 Write a failing test: a `409` surfaces as `PathConflictException` (reusing the existing type — an attachment name collision is the same class of failure as a note path collision)
- [ ] 6.3 Write a failing test: a `413` surfaces as a typed exception carrying the server's error message (new `PayloadTooLargeException`, following the existing `ApiException` hierarchy)
- [ ] 6.4 Implement `RobotNotesClient.uploadFile`; run 6.1–6.3 green
- [ ] 6.5 Commit: `feat(app): add RobotNotesClient.uploadFile`

## 7. Flutter: FAB "Upload file" action

- [ ] 7.1 Add the `file_picker` dependency to `app/pubspec.yaml` and verify `flutter pub get` resolves cleanly on at least the platforms CI builds (see `release-pipeline`)
- [ ] 7.2 Write a failing widget test: the FAB menu (from `add-empty-folder-creation`) renders a third "Upload file" item alongside "New note" and "New folder"
- [ ] 7.3 Write a failing widget test: choosing "Upload file" and picking a file (inject a fake picker result) calls `uploadFile` with `path` set to the currently selected folder, falling back to `""` when none is selected
- [ ] 7.4 Write a failing widget test: dismissing the file picker without choosing a file sends no request
- [ ] 7.5 Write a failing widget test: a successful upload shows a confirmation naming the stored filename
- [ ] 7.6 Write a failing widget test: a failed upload shows the server's error message via the existing `describeError()` helper, matching the "New folder" error-handling convention
- [ ] 7.7 Implement the "Upload file" menu item, the file-picker call (wrapped so tests can inject a fake picker), and success/error handling in `notes_list_screen.dart` / `app_router.dart`; run 7.2–7.6 green
- [ ] 7.8 Commit: `feat(app): add "Upload file" to the FAB menu`

## 8. Docs and end-to-end check

- [ ] 8.1 Run the full server and app test suites; fix any regressions
- [ ] 8.2 Update `server/STORAGE.md` to document attachment files as a third on-disk artifact kind, alongside notes and empty-folder markers
- [ ] 8.3 Update `server/API.md` to document `POST /notes/attachments`, `GET /notes/attachments/{path}`, and the `upload_file` MCP tool, including the size-limit config setting
- [ ] 8.4 Manually verify against a running server + app: upload a file from the FAB into a selected folder, confirm it's retrievable via `GET /notes/attachments/{path}` with the correct bytes and content-type, confirm a same-name re-upload is rejected with 409, confirm an oversized upload is rejected with 413 and leaves no partial file; call `upload_file` over MCP directly (e.g. via `curl` against `/mcp`) and confirm the same file shows up on disk
- [ ] 8.5 Commit: `docs(server): document attachment uploads, upload_file, and the max-upload-size setting`

## Definition of Done

- All tasks above checked off, each with its own green test run and its own commit
- `openspec validate add-file-upload --strict` passes
- Full server (`dart test`) and Flutter (`flutter test`) suites pass
- An uploaded attachment survives a server restart and remains retrievable, whether uploaded via REST or via `upload_file`
- No `TODO`/`FIXME` left from this change in touched files
