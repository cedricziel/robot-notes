## MODIFIED Requirements

### Requirement: tools/list returns the fixed note tool catalog

`tools/list` SHALL return exactly these tools, each with a `description` and a JSON Schema `inputSchema` of type `object` declaring the listed properties and `required` set: `list_notes` (`limit` integer 1..200, `after` string, `path` string, `tag` string), `get_note` (`id` required), `create_note` (`title` required, `content`, `path`), `update_note` (`id` and `version` required, `title`, `content`, `path`), `append_to_note` (`id` and `text` required), `delete_note` (`id` required), `search_notes` (`query` required, `limit` integer 1..100, `path` string, `tag` string), `move_note` (`id` and `version` required, `path` required), `get_backlinks` (`id` required), `upload_file` (`path`, `filename`, and `content_base64` required, `content_type` optional). The catalog SHALL be the same regardless of the caller's scopes. The result SHALL NOT include a `nextCursor`.

#### Scenario: Catalog contents

- **WHEN** an authenticated client sends `tools/list`
- **THEN** the result `tools` array SHALL contain exactly the ten names above (or eleven once `create_folder` from `add-empty-folder-creation` has also landed), each with `inputSchema.type == "object"`

#### Scenario: Required fields are declared

- **WHEN** the client inspects the `update_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version"]`

#### Scenario: move_note requires id, version, and path

- **WHEN** the client inspects the `move_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version", "path"]`

#### Scenario: upload_file requires path, filename, and content_base64

- **WHEN** the client inspects the `upload_file` entry
- **THEN** `inputSchema.required` SHALL equal `["path", "filename", "content_base64"]`

## ADDED Requirements

### Requirement: upload_file mirrors POST /notes/attachments

`upload_file` SHALL accept `{ path, filename, content_base64, content_type? }`, decode `content_base64` as standard base64, and behave identically to `POST /notes/attachments` (per the `attachments` capability): the same path/filename sanitization, the same collision check (`path_conflict` tool error, matching the existing `create_note`/`update_note`/`move_note` convention rather than a new error code), and the same configured maximum upload size (checked against the decoded byte length, not the base64 string length) resulting in a `payload_too_large` tool error. On success it SHALL return `{ path, filename, size, content_type }` as `structuredContent`, matching the REST endpoint's response shape.

#### Scenario: Uploading a small file

- **WHEN** a client calls `upload_file` with `path: "Ideas"`, `filename: "note.txt"`, and `content_base64` encoding `"hello"`
- **THEN** the result SHALL have `structuredContent == { "path": "Ideas", "filename": "note.txt", "size": 5, "content_type": "text/plain" }` and `isError` SHALL be absent or `false`
- **AND** the file SHALL be readable via `GET /notes/attachments/Ideas/note.txt`

#### Scenario: A filename collision is a path_conflict tool error

- **GIVEN** `Ideas/note.txt` already exists
- **WHEN** a client calls `upload_file` with `path: "Ideas"` and `filename: "note.txt"` again
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "path_conflict"`

#### Scenario: A decoded payload over the configured limit is a payload_too_large tool error

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client calls `upload_file` with `content_base64` decoding to more than 25 MiB
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "payload_too_large"`

#### Scenario: Malformed base64 is a validation_failed tool error

- **WHEN** a client calls `upload_file` with `content_base64` that is not valid base64
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`
