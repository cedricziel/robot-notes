## Purpose

Lets a client store and retrieve arbitrary non-note files (images, PDFs, and other reference material) inside the vault's existing folder structure, alongside notes, without those files being treated as notes by any note-shaped operation.

## ADDED Requirements

### Requirement: POST /notes/attachments uploads a file into a folder

`POST /notes/attachments` SHALL accept a `multipart/form-data` body with a `path` field (the target folder, using the same `/`-separated, no-leading/trailing-slash convention as a note's `path`) and a `file` field (the binary upload, carrying its own filename), sanitize and normalize both the folder path and the filename using the same rules a note's path/title already go through, write the file to that folder (creating intermediate folders as needed), and respond `201 Created` with `{ "path": "<folder>", "filename": "<sanitized-filename>", "size": <bytes>, "content_type": "<detected-or-declared-type>" }`. The endpoint SHALL require authentication.

#### Scenario: Uploading a file to the vault root

- **WHEN** a client posts a multipart body with `path: ""` and a file named `diagram.png`
- **THEN** the response SHALL be `201 Created` with `{ "path": "", "filename": "diagram.png", ... }`
- **AND** the file SHALL be readable via `GET /notes/attachments/diagram.png`

#### Scenario: Uploading into a nested folder creates intermediate folders

- **WHEN** a client posts a multipart body with `path: "Projects/Alpha"` and a file named `notes.pdf`, and no part of that path exists yet
- **THEN** the response SHALL be `201 Created`
- **AND** the folder chain SHALL be created exactly as `POST /notes/tree` would create it

#### Scenario: An invalid path segment is rejected

- **WHEN** a client posts a multipart body with `path: "../etc"` and any file
- **THEN** the response SHALL be `400 Bad Request`

### Requirement: A filename collision is rejected, not overwritten or renamed

`POST /notes/attachments` SHALL respond `409 Conflict` when the sanitized target `<path>/<filename>` already refers to an existing file (an attachment, a note, or an empty-folder marker), and SHALL NOT modify or overwrite the existing file.

#### Scenario: Uploading a file with a name that already exists

- **GIVEN** `Ideas/diagram.png` already exists
- **WHEN** a client posts a new upload with `path: "Ideas"` and a file named `diagram.png`
- **THEN** the response SHALL be `409 Conflict`
- **AND** the existing `Ideas/diagram.png` SHALL be unchanged

### Requirement: An oversized upload is rejected before being written to disk

`POST /notes/attachments` SHALL enforce a configured maximum upload size (see the server's `notes-storage` configuration) and respond `413 Payload Too Large` for a request whose body exceeds it, without creating a partial file on disk.

#### Scenario: A file larger than the configured limit is rejected

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client uploads a 30 MiB file
- **THEN** the response SHALL be `413 Payload Too Large`
- **AND** no file SHALL be created at the target path

### Requirement: GET /notes/attachments/{path} retrieves an uploaded file

`GET /notes/attachments/{path}` SHALL stream back the raw bytes of the file at the given `/`-separated `path` (folder plus filename) with a `Content-Type` derived from the file's extension (falling back to `application/octet-stream` when the extension is unrecognized), and respond `404 Not Found` when no file exists at that path. The endpoint SHALL require authentication.

#### Scenario: Retrieving a previously uploaded file

- **GIVEN** a file was uploaded to `Ideas/diagram.png`
- **WHEN** a client requests `GET /notes/attachments/Ideas/diagram.png`
- **THEN** the response SHALL be `200 OK` with the original bytes and a `Content-Type` of `image/png`

#### Scenario: Requesting a path with no file

- **WHEN** a client requests `GET /notes/attachments/does-not-exist.png`
- **THEN** the response SHALL be `404 Not Found`
