## MODIFIED Requirements

### Requirement: tools/list returns the fixed note tool catalog

`tools/list` SHALL return exactly these tools, each with a `description` and a JSON Schema `inputSchema` of type `object` declaring the listed properties and `required` set: `list_notes` (`limit` integer 1..200, `after` string, `path` string, `tag` string), `get_note` (`id` required), `create_note` (`title` required, `content`, `path`), `update_note` (`id` and `version` required, `title`, `content`, `path`), `append_to_note` (`id` and `text` required), `delete_note` (`id` required), `search_notes` (`query` required, `limit` integer 1..100, `path` string, `tag` string), `move_note` (`id` and `version` required, `path` required), `get_backlinks` (`id` required), `create_folder` (`path` required), `request_upload` (`path` and `filename` required, `size_bytes` optional), `finalize_upload` (`token` required). The catalog SHALL be the same regardless of the caller's scopes. The result SHALL NOT include a `nextCursor`.

#### Scenario: Catalog contents

- **WHEN** an authenticated client sends `tools/list`
- **THEN** the result `tools` array SHALL contain exactly the twelve names above, each with `inputSchema.type == "object"`

#### Scenario: Required fields are declared

- **WHEN** the client inspects the `update_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version"]`

#### Scenario: move_note requires id, version, and path

- **WHEN** the client inspects the `move_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version", "path"]`

#### Scenario: request_upload requires path and filename but not size_bytes

- **WHEN** the client inspects the `request_upload` entry
- **THEN** `inputSchema.required` SHALL equal `["path", "filename"]`

#### Scenario: finalize_upload requires only token

- **WHEN** the client inspects the `finalize_upload` entry
- **THEN** `inputSchema.required` SHALL equal `["token"]`

## ADDED Requirements

### Requirement: request_upload reserves a token-authenticated upload slot

`request_upload` SHALL accept `{ path, filename, size_bytes? }` and behave per the `vault-files` capability's `request_upload` requirement: reserving a single-use, short-lived upload slot and returning `{ upload_url, token, expires_at }` as `structuredContent`. A `size_bytes` over the configured maximum upload size SHALL fail with a `payload_too_large` tool error before any slot is reserved.

#### Scenario: Reserving an upload slot over MCP

- **WHEN** a client calls `request_upload` with `path: "Ideas"`, `filename: "photo.png"`
- **THEN** the result SHALL have `structuredContent` containing `token`, `upload_url`, and `expires_at`, and `isError` SHALL be absent or `false`

#### Scenario: A declared size over the limit is a payload_too_large tool error

- **GIVEN** the server's maximum upload size is configured to 25 MiB
- **WHEN** a client calls `request_upload` with `size_bytes` greater than 25 MiB
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "payload_too_large"`

### Requirement: finalize_upload places a completed upload into the vault

`finalize_upload` SHALL accept `{ token }` and behave per the `vault-files` capability's `finalize_upload` requirement: placing a completed upload's staged bytes into the vault at the `path`/`filename` reserved by the corresponding `request_upload` call, returning `{ path, filename, size, content_type }` as `structuredContent` on success — using the identical sanitization, collision, and atomic-write path `POST /notes/files` uses. A `token` that is missing, expired, or whose upload has not yet completed SHALL fail with a `validation_failed` tool error. A collision discovered at finalize time SHALL fail with a `path_conflict` tool error (reusing `kErrorPathConflict`, the same code `create_note`/`update_note`/`move_note` already return for a note path collision).

#### Scenario: Finalizing a completed upload over MCP

- **GIVEN** a client called `request_upload` for `path: "Ideas"`, `filename: "photo.png"`, and then `PUT` the file's bytes to the returned `upload_url`
- **WHEN** the client calls `finalize_upload` with that `token`
- **THEN** the result SHALL have `structuredContent == { "path": "Ideas", "filename": "photo.png", "size": <bytes>, "content_type": "image/png" }`

#### Scenario: An unknown or not-yet-uploaded token is a validation_failed tool error

- **WHEN** a client calls `finalize_upload` with a `token` that was never reserved, or that was reserved but never completed via `PUT`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`

#### Scenario: A filename collision at finalize time is a path_conflict tool error

- **GIVEN** `Ideas/photo.png` already exists, and a token reserved for that same `path`/`filename` has completed its `PUT`
- **WHEN** a client calls `finalize_upload` with that `token`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "path_conflict"`
