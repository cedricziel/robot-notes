## ADDED Requirements

### Requirement: Opt-in upload tool

The Hermes memory provider SHALL advertise and accept `robotnotes_upload_file` only when `upload_roots` names at least one directory and native tools are enabled.

#### Scenario: No roots configured

- **WHEN** `upload_roots` is empty or absent
- **THEN** `get_tool_schemas` SHALL NOT include `robotnotes_upload_file`, and a call to it SHALL return an `uploads_disabled` tool error without contacting the server

#### Scenario: Roots configured

- **WHEN** `upload_roots` names a directory
- **THEN** `get_tool_schemas` SHALL include `robotnotes_upload_file` and the system prompt SHALL list it

#### Scenario: Invalid roots configuration

- **WHEN** `upload_roots` is not a list of absolute path strings
- **THEN** loading the configuration SHALL fail with a validation error

### Requirement: File bytes stay out of model context

The tool SHALL accept a local file path, never file content, and SHALL return only the server's upload metadata.

#### Scenario: Successful upload

- **WHEN** the model calls `robotnotes_upload_file` with `local_path` naming a regular file under a configured root, and an optional vault folder `path` and `filename`
- **THEN** the provider SHALL stream the file to `POST /notes/files` as multipart form data and return exactly `{path, filename, size, content_type}` from the server response

#### Scenario: Filename defaults to the local name

- **WHEN** `filename` is omitted
- **THEN** the uploaded file SHALL use the local file's base name

### Requirement: Reads are confined to configured roots

The provider SHALL refuse any `local_path` that, after expanding `~` and resolving symlinks and `..`, is not a regular file at or under a configured root, and SHALL refuse paths blocked by the host's read denylist when available.

#### Scenario: Path escapes a root

- **WHEN** `local_path` resolves outside every root, including through a symlink or `..`
- **THEN** the tool SHALL return an `upload_path_denied` error and SHALL NOT read the file or contact the server

#### Scenario: Relative, missing, or non-regular path

- **WHEN** `local_path` is relative, does not exist, or names a directory
- **THEN** the tool SHALL return an `upload_path_invalid` error without contacting the server

#### Scenario: Host denylist

- **WHEN** Hermes' read denylist blocks the resolved path
- **THEN** the tool SHALL return an `upload_path_denied` error

### Requirement: Upload is a write

The tool SHALL obey the provider's read-only contexts.

#### Scenario: Read-only context

- **WHEN** the provider runs in a subagent, cron, or flush context
- **THEN** the tool SHALL return a `read_only` error without reading the file

### Requirement: Server rejections are reported, not retried

The tool SHALL report the server's error code and SHALL NOT overwrite, rename, or retry on its own.

#### Scenario: Name collision

- **WHEN** the server responds `409 path_conflict`
- **THEN** the tool SHALL return a `path_conflict` error

#### Scenario: Oversized or forbidden upload

- **WHEN** the server responds `413 payload_too_large` or `422 canonical_note_upload_forbidden`
- **THEN** the tool SHALL return that error code
