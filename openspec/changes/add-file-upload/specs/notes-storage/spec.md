## ADDED Requirements

### Requirement: Uploaded files are indexed the same lightweight way empty-folder markers are

An uploaded file (see `vault-files`) SHALL be stored as a plain file at `<data-dir>/content/<path>/<sanitized-filename>`, using the same folder-path sanitization rules as a note's `path`. It SHALL NOT be treated as a note by any note-shaped scan or operation: it SHALL be excluded from `Storage.list()`/note enumeration, `GET /notes`, `GET /search`, link parsing, and tag computation, the same way an empty-folder marker file already is. It SHALL, however, be tracked in a lightweight file index (path, size, modified time) so it contributes to folder discoverability (see `vault-files`'s tree and listing requirements) without being indexed as a note.

#### Scenario: An uploaded file does not appear as a note

- **GIVEN** a file was uploaded to `Ideas/diagram.png`
- **WHEN** a client requests `GET /notes` or `GET /search?q=diagram`
- **THEN** the file SHALL NOT appear in either response

#### Scenario: A file coexists with notes and folder markers in the same folder

- **GIVEN** folder `Ideas` contains a note, an empty-folder marker, and an uploaded file
- **WHEN** the server scans `<data-dir>/content/` on startup
- **THEN** all three SHALL continue to exist on disk, and only the note SHALL be indexed as a note

### Requirement: A staging upload's bytes are never scanned as vault content

Bytes staged by an in-progress or abandoned upload session (see `vault-files`'s `PUT /notes/file-uploads/{token}`) SHALL live outside `<data-dir>/content/` entirely, and SHALL NOT appear in any note scan, file index, folder tree, or file listing until `finalize_upload` places them at their final path.

#### Scenario: A staged-but-not-finalized upload is invisible to the vault

- **GIVEN** a client completed the `PUT` step of an upload but has not yet called `finalize_upload`
- **WHEN** a client requests `GET /notes/tree` or `GET /notes/files?path=<the reserved folder>`
- **THEN** the staged file SHALL NOT appear in either response

### Requirement: Maximum upload size is configurable but defaults to 25 MiB

The server SHALL default the maximum accepted upload size to 25 MiB (26,214,400 bytes). Operators MAY override via a `--max-upload-size-bytes <n>` CLI argument or `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` env var. The configured limit SHALL apply to every `POST /notes/files` request and every completed `PUT /notes/file-uploads/{token}` transfer.

#### Scenario: The default limit applies when unconfigured

- **GIVEN** the server is started without `--max-upload-size-bytes` or the env var set
- **WHEN** a client uploads a file larger than 25 MiB via either upload path
- **THEN** the request SHALL be rejected per the `vault-files` capability's oversized-upload requirements

#### Scenario: An operator raises the limit

- **GIVEN** the server is started with `--max-upload-size-bytes 52428800`
- **WHEN** a client uploads a 30 MiB file via either upload path
- **THEN** the upload SHALL succeed
