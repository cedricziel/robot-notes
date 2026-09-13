## Purpose

Lets a client store, retrieve, and browse arbitrary non-note files (images, PDFs, and other reference material) inside the vault's existing folder structure, alongside notes — as first-class, discoverable vault entries, not a separate walled-off concept. Provides both a one-shot upload path for clients that already hold the file's bytes (a real HTTP client) and a two-phase, token-based upload path for callers that must not embed those bytes in a control-plane call (an MCP-driven agent).

## ADDED Requirements

### Requirement: POST /notes/files uploads a file into a folder directly

`POST /notes/files` SHALL accept a `multipart/form-data` body with a `path` field (the target folder, using the same `/`-separated, no-leading/trailing-slash convention as a note's `path`) and a `file` field (the binary upload, carrying its own filename), sanitize and normalize both the folder path and the filename using the same rules a note's path/title already go through, write the file to that folder (creating intermediate folders as needed), and respond `201 Created` with `{ "path": "<folder>", "filename": "<sanitized-filename>", "size": <bytes>, "content_type": "<detected-or-declared-type>" }`. The endpoint SHALL require authentication.

#### Scenario: Uploading a file to the vault root

- **WHEN** a client posts a multipart body with `path: ""` and a file named `diagram.png`
- **THEN** the response SHALL be `201 Created` with `{ "path": "", "filename": "diagram.png", ... }`
- **AND** the file SHALL be readable via `GET /notes/files/diagram.png`

#### Scenario: Uploading into a nested folder creates intermediate folders

- **WHEN** a client posts a multipart body with `path: "Projects/Alpha"` and a file named `notes.pdf`, and no part of that path exists yet
- **THEN** the response SHALL be `201 Created`
- **AND** the folder chain SHALL be created exactly as `POST /notes/tree` would create it

#### Scenario: An invalid path segment is rejected

- **WHEN** a client posts a multipart body with `path: "../etc"` and any file
- **THEN** the response SHALL be `400 Bad Request`

### Requirement: A filename collision is rejected, not overwritten or renamed

`POST /notes/files` SHALL respond `409 Conflict` when the sanitized target `<path>/<filename>` already refers to an existing file (another uploaded file, a note, or an empty-folder marker), and SHALL NOT modify or overwrite the existing file.

#### Scenario: Uploading a file with a name that already exists

- **GIVEN** `Ideas/diagram.png` already exists
- **WHEN** a client posts a new upload with `path: "Ideas"` and a file named `diagram.png`
- **THEN** the response SHALL be `409 Conflict`
- **AND** the existing `Ideas/diagram.png` SHALL be unchanged

### Requirement: An oversized upload is rejected before being written to disk

`POST /notes/files` SHALL enforce a configured maximum upload size (see the server's `notes-storage` configuration) and respond `413 Payload Too Large` for a request whose body exceeds it, without creating a partial file on disk.

#### Scenario: A file larger than the configured limit is rejected

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client uploads a 30 MiB file
- **THEN** the response SHALL be `413 Payload Too Large`
- **AND** no file SHALL be created at the target path

### Requirement: GET /notes/files/{path} retrieves a file's bytes

`GET /notes/files/{path}` SHALL stream back the raw bytes of the file at the given `/`-separated `path` (folder plus filename) with a `Content-Type` derived from the file's extension (falling back to `application/octet-stream` when the extension is unrecognized), and respond `404 Not Found` when no file exists at that path. The endpoint SHALL require authentication.

#### Scenario: Retrieving a previously uploaded file

- **GIVEN** a file was uploaded to `Ideas/diagram.png`
- **WHEN** a client requests `GET /notes/files/Ideas/diagram.png`
- **THEN** the response SHALL be `200 OK` with the original bytes and a `Content-Type` of `image/png`

#### Scenario: Requesting a path with no file

- **WHEN** a client requests `GET /notes/files/does-not-exist.png`
- **THEN** the response SHALL be `404 Not Found`

### Requirement: GET /notes/files?path= lists a folder's files

`GET /notes/files?path=<folder>` SHALL return every file directly inside `<folder>` (not recursing into subfolders) as `{ "items": [{ "path": "<folder>", "filename": "<name>", "size": <bytes>, "content_type": "<type>", "updated_at": "<iso8601>" }] }`. An empty or omitted `path` SHALL list the vault root's direct files. The result SHALL NOT include files from subfolders and SHALL NOT include notes.

#### Scenario: Listing files in a folder

- **GIVEN** `Ideas/diagram.png` and `Ideas/notes.pdf` exist, and `Ideas/Sub/other.png` also exists
- **WHEN** a client requests `GET /notes/files?path=Ideas`
- **THEN** the result `items` SHALL contain `diagram.png` and `notes.pdf` but not `Sub/other.png`

### Requirement: A folder holding only files still appears in GET /notes/tree

`GET /notes/tree` SHALL include a folder that holds at least one file, even if it holds no notes and no empty-folder marker, alongside its file count as `file_count`.

#### Scenario: A file-only folder is discoverable via the tree

- **GIVEN** folder `Attachments` contains only an uploaded file, no notes, and no empty-folder marker
- **WHEN** a client requests `GET /notes/tree`
- **THEN** the result SHALL include an entry for `Attachments` with `file_count >= 1`

### Requirement: request_upload reserves a token-authenticated upload slot

An MCP client SHALL be able to call `request_upload` with `{ path, filename, size_bytes? }` to reserve a single-use upload slot, receiving `{ upload_url, token, expires_at }` in response. `upload_url` SHALL be a path relative to the same server the MCP request reached (e.g. `/notes/files/uploads/<token>`), suitable for a `PUT` carrying the raw file bytes. When `size_bytes` is supplied and exceeds the server's configured maximum upload size, the call SHALL fail immediately with a `payload_too_large` tool error rather than minting a token that could never be completed.

#### Scenario: Reserving an upload slot

- **WHEN** a client calls `request_upload` with `path: "Ideas"` and `filename: "photo.png"`
- **THEN** the result SHALL have `structuredContent` containing `token`, `upload_url`, and `expires_at`, and `isError` SHALL be absent or `false`

#### Scenario: A declared size over the limit is rejected up front

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client calls `request_upload` with `size_bytes` greater than 25 MiB
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "payload_too_large"`
- **AND** no upload slot SHALL be created

### Requirement: PUT /notes/files/uploads/{token} completes an upload slot with raw bytes

`PUT /notes/files/uploads/{token}` SHALL accept the raw request body as the file's bytes (not multipart), authenticated by possession of a valid, unexpired, not-yet-completed `token` alone — no `Authorization` header is required. On success it SHALL respond `200 OK` with `{ token, size, content_type, expires_at }`. It SHALL enforce the same maximum-upload-size limit as `POST /notes/files`, aborting and discarding any partial data if exceeded. A missing, expired, or already-completed token SHALL respond `404 Not Found`.

#### Scenario: Completing a reserved upload

- **GIVEN** `request_upload` returned a token for `path: "Ideas"`, `filename: "photo.png"`
- **WHEN** a client `PUT`s the file's bytes to that token's `upload_url`, without any `Authorization` header
- **THEN** the response SHALL be `200 OK` with `{ token, size, content_type, expires_at }`

#### Scenario: An expired token cannot be completed

- **GIVEN** a token was reserved and its `expires_at` has passed
- **WHEN** a client `PUT`s bytes to it
- **THEN** the response SHALL be `404 Not Found`

#### Scenario: A token can only be completed once

- **GIVEN** a token's upload already completed successfully
- **WHEN** a client `PUT`s to it again
- **THEN** the response SHALL be `404 Not Found`

#### Scenario: An oversized PUT is rejected without leaving a partial file

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client `PUT`s a 30 MiB body to a valid token
- **THEN** the response SHALL be `413 Payload Too Large`
- **AND** no staged file SHALL remain for that token

### Requirement: finalize_upload places a completed upload into the vault

An MCP client SHALL be able to call `finalize_upload` with `{ token }` to place a completed upload's bytes into the vault at the `path`/`filename` reserved by the corresponding `request_upload` call, returning `{ path, filename, size, content_type }` on success — using the identical sanitization, collision, and atomic-write path `POST /notes/files` uses. A `token` that is missing, expired, or whose upload has not yet completed SHALL fail with a `validation_failed` tool error. A collision discovered at finalize time SHALL fail with a `path_conflict` tool error, and the reserved slot SHALL be discarded either way (a caller must `request_upload` again to retry).

#### Scenario: Finalizing a completed upload

- **GIVEN** a token's upload has completed via `PUT`
- **WHEN** a client calls `finalize_upload` with that `token`
- **THEN** the result SHALL have `structuredContent == { "path": "Ideas", "filename": "photo.png", "size": <bytes>, "content_type": "image/png" }`
- **AND** the file SHALL be readable via `GET /notes/files/Ideas/photo.png`

#### Scenario: Finalizing before the PUT completes fails validation

- **GIVEN** a token was reserved via `request_upload` but no `PUT` has completed for it
- **WHEN** a client calls `finalize_upload` with that `token`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`

#### Scenario: A collision at finalize time is a path_conflict tool error

- **GIVEN** `Ideas/photo.png` already exists, and a token was reserved for that same `path`/`filename` and completed via `PUT` before the collision was created
- **WHEN** a client calls `finalize_upload` with that `token`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "path_conflict"`
- **AND** the existing `Ideas/photo.png` SHALL be unchanged
