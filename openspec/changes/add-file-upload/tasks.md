## 1. Config: max upload size

- [ ] 1.1 Write a failing test: `Config.fromArgs` defaults `maxUploadSizeBytes` to 26,214,400 (25 MiB) when neither `--max-upload-size-bytes` nor `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` is set
- [ ] 1.2 Write a failing test: `--max-upload-size-bytes 52428800` overrides the default
- [ ] 1.3 Write a failing test: `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` env var overrides the default when the CLI flag is absent, and the CLI flag wins when both are set
- [ ] 1.4 Implement `maxUploadSizeBytes` on `Config`, following the same CLI-then-env-then-default resolution as `lockTtlSeconds`; run 1.1–1.3 green
- [ ] 1.5 Commit: `feat(server): add a configurable max upload size setting`

## 2. Server: attachment path resolution and collision detection

- [ ] 2.1 Write a failing test: sanitizing `path: "Projects/Alpha"` + `filename: "My File.PNG"` normalizes and strips illegal characters the same way a note's path/title do (reusing `sanitizedPathSegments`/`sanitizeFilenameSegment`/`normalizeToNfc`)
- [ ] 2.2 Write a failing test: an invalid path segment (`.`, `..`, or empty-after-sanitizing) throws `InvalidPathException`, matching `Storage.createFolder`
- [ ] 2.3 Write a failing test: the resolved target collides (case/NFC-insensitively, via `collisionKey`) with an existing note file, an existing attachment, or an existing empty-folder marker — all three count as a collision
- [ ] 2.4 Write a failing test: a target with no collision resolves cleanly with no side effects (pure check, nothing written yet)
- [ ] 2.5 Implement the sanitization + collision check (per design.md, as a small helper alongside `Storage` — promote it to a `Storage` method instead only if that ends up simpler once written); run 2.1–2.4 green
- [ ] 2.6 Commit: `feat(server): add attachment path sanitization and collision detection`

## 3. Server: POST /notes/attachments

- [ ] 3.1 Write a failing route test: posting a multipart body with `path: ""` and a small file returns `201 Created` with `{ path: "", filename, size, content_type }`, and the file exists on disk with the exact bytes sent
- [ ] 3.2 Write a failing route test: `path: "Projects/Alpha"` with intermediates that don't exist yet creates the full folder chain (same behavior as `POST /notes/tree`)
- [ ] 3.3 Write a failing route test: a filename colliding with an existing file at the target path returns `409 Conflict` and does not modify the existing file
- [ ] 3.4 Write a failing route test: a body exceeding the configured `maxUploadSizeBytes` (mock a small limit for the test) returns `413 Payload Too Large` and leaves no partial file at the target path
- [ ] 3.5 Write a failing route test: an invalid `path` segment returns `400 Bad Request`
- [ ] 3.6 Write a failing route test: a request missing the `file` field, or missing `path`, returns `400 Bad Request`
- [ ] 3.7 Implement `POST /notes/attachments` using `context.request.formData()`, writing via the same tmp+fsync+rename pattern `Storage` uses for notes, streaming `UploadedFile.openRead()` chunk-by-chunk with a running byte count enforced against the configured limit (per design.md — no `readAsBytes()`), serialized per target-path collision key; run 3.1–3.6 green
- [ ] 3.8 Commit: `feat(server): add POST /notes/attachments`

## 4. Server: GET /notes/attachments/{path}

- [ ] 4.1 Write a failing route test: requesting a previously-uploaded file's path returns `200 OK` with the original bytes and a `Content-Type` derived from the extension (e.g. `.png` → `image/png`)
- [ ] 4.2 Write a failing route test: a nested path (`Projects/Alpha/diagram.png`) resolves correctly
- [ ] 4.3 Write a failing route test: a path with no file at it returns `404 Not Found`
- [ ] 4.4 Write a failing route test: an unrecognized extension falls back to `application/octet-stream`
- [ ] 4.5 Implement `GET /notes/attachments/[...path]` as a catch-all route (per design.md), resolving content-type via the `mime` package; run 4.1–4.4 green
- [ ] 4.6 Commit: `feat(server): add GET /notes/attachments/{path} to retrieve uploads`

## 5. Flutter: upload API client method

- [ ] 5.1 Write a failing test in `api_client_test.dart`: a new `uploadFile({required String path, required String filename, required List<int> bytes, String? contentType})` method POSTs a multipart request to `/notes/attachments` with the given fields and returns the decoded `{path, filename, size, content_type}`
- [ ] 5.2 Write a failing test: a `409` surfaces as `PathConflictException` (reusing the existing type — an attachment name collision is the same class of failure as a note path collision)
- [ ] 5.3 Write a failing test: a `413` surfaces as a typed exception carrying the server's error message (new `PayloadTooLargeException`, following the existing `ApiException` hierarchy)
- [ ] 5.4 Implement `RobotNotesClient.uploadFile`; run 5.1–5.3 green
- [ ] 5.5 Commit: `feat(app): add RobotNotesClient.uploadFile`

## 6. Flutter: FAB "Upload file" action

- [ ] 6.1 Add the `file_picker` dependency to `app/pubspec.yaml` and verify `flutter pub get` resolves cleanly on at least the platforms CI builds (see `release-pipeline`)
- [ ] 6.2 Write a failing widget test: the FAB menu (from `add-empty-folder-creation`) renders a third "Upload file" item alongside "New note" and "New folder"
- [ ] 6.3 Write a failing widget test: choosing "Upload file" and picking a file (inject a fake picker result) calls `uploadFile` with `path` set to the currently selected folder, falling back to `""` when none is selected
- [ ] 6.4 Write a failing widget test: dismissing the file picker without choosing a file sends no request
- [ ] 6.5 Write a failing widget test: a successful upload shows a confirmation naming the stored filename
- [ ] 6.6 Write a failing widget test: a failed upload shows the server's error message via the existing `describeError()` helper, matching the "New folder" error-handling convention
- [ ] 6.7 Implement the "Upload file" menu item, the file-picker call (wrapped so tests can inject a fake picker), and success/error handling in `notes_list_screen.dart` / `app_router.dart`; run 6.2–6.6 green
- [ ] 6.8 Commit: `feat(app): add "Upload file" to the FAB menu`

## 7. Docs and end-to-end check

- [ ] 7.1 Run the full server and app test suites; fix any regressions
- [ ] 7.2 Update `server/STORAGE.md` to document attachment files as a third on-disk artifact kind, alongside notes and empty-folder markers
- [ ] 7.3 Update `server/API.md` to document `POST /notes/attachments` and `GET /notes/attachments/{path}`, including the size-limit config setting
- [ ] 7.4 Manually verify against a running server + app: upload a file from the FAB into a selected folder, confirm it's retrievable via `GET /notes/attachments/{path}` with the correct bytes and content-type, confirm a same-name re-upload is rejected with 409, confirm an oversized upload is rejected with 413 and leaves no partial file
- [ ] 7.5 Commit: `docs(server): document attachment uploads and the max-upload-size setting`

## Definition of Done

- All tasks above checked off, each with its own green test run and its own commit
- `openspec validate add-file-upload --strict` passes
- Full server (`dart test`) and Flutter (`flutter test`) suites pass
- An uploaded attachment survives a server restart and remains retrievable
- No `TODO`/`FIXME` left from this change in touched files
