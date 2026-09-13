## ADDED Requirements

### Requirement: Attachment files are a third kind of on-disk artifact

An uploaded attachment (see `attachments`) SHALL be stored as a plain file at `<data-dir>/content/<path>/<sanitized-filename>`, using the same folder-path sanitization rules as a note's `path`. An attachment file SHALL NOT be treated as a note by any note-shaped scan or operation: it SHALL be excluded from `Storage.list()`/note enumeration, `GET /notes`, `GET /search`, link parsing, and tag computation, the same way an empty-folder marker file already is.

#### Scenario: An uploaded attachment does not appear as a note

- **GIVEN** a file was uploaded to `Ideas/diagram.png`
- **WHEN** a client requests `GET /notes` or `GET /search?q=diagram`
- **THEN** the attachment SHALL NOT appear in either response

#### Scenario: An attachment coexists with notes and folder markers in the same folder

- **GIVEN** folder `Ideas` contains a note, an empty-folder marker, and an uploaded attachment
- **WHEN** the server scans `<data-dir>/content/` on startup
- **THEN** all three SHALL continue to exist on disk, and only the note SHALL be indexed as a note

### Requirement: Maximum upload size is configurable but defaults to 25 MiB

The server SHALL default the maximum accepted attachment upload size to 25 MiB (26,214,400 bytes). Operators MAY override via a `--max-upload-size-bytes <n>` CLI argument or `ROBOT_NOTES_MAX_UPLOAD_SIZE_BYTES` env var. The configured limit SHALL apply to every `POST /notes/attachments` request.

#### Scenario: The default limit applies when unconfigured

- **GIVEN** the server is started without `--max-upload-size-bytes` or the env var set
- **WHEN** a client uploads a file larger than 25 MiB
- **THEN** the request SHALL be rejected per the `attachments` capability's oversized-upload requirement

#### Scenario: An operator raises the limit

- **GIVEN** the server is started with `--max-upload-size-bytes 52428800`
- **WHEN** a client uploads a 30 MiB file
- **THEN** the upload SHALL succeed
