## MODIFIED Requirements

### Requirement: tools/list returns the fixed note tool catalog

`tools/list` SHALL return exactly these tools, each with a `description` and a JSON Schema `inputSchema` of type `object` declaring the listed properties and `required` set: `list_notes` (`limit` integer 1..200, `after` string, `path` string, `tag` string), `get_note` (`id` required), `create_note` (`title` required, `content`, `path`), `update_note` (`id` and `version` required, `title`, `content`, `path`), `append_to_note` (`id` and `text` required), `delete_note` (`id` required), `search_notes` (`query` required, `limit` integer 1..100, `path` string, `tag` string), `move_note` (`id` and `version` required, `path` required), `get_backlinks` (`id` required), `create_folder` (`path` required). The catalog SHALL be the same regardless of the caller's scopes. The result SHALL NOT include a `nextCursor`.

#### Scenario: Catalog contents

- **WHEN** an authenticated client sends `tools/list`
- **THEN** the result `tools` array SHALL contain exactly the ten names above, each with `inputSchema.type == "object"`

#### Scenario: Required fields are declared

- **WHEN** the client inspects the `update_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version"]`

#### Scenario: move_note requires id, version, and path

- **WHEN** the client inspects the `move_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version", "path"]`

#### Scenario: create_folder requires path

- **WHEN** the client inspects the `create_folder` entry
- **THEN** `inputSchema.required` SHALL equal `["path"]`

## ADDED Requirements

### Requirement: create_folder mirrors POST /notes/tree

`create_folder` SHALL accept `{ path }` and behave identically to `POST /notes/tree` (per `notes-api`): it SHALL create the folder (and any missing intermediate folders) if absent, or succeed as a no-op if the folder already exists, returning `{ path, note_count }` as `structuredContent` in both cases — there is no error case that distinguishes "created" from "already existed". An empty `path` SHALL be a `validation_failed` tool error, matching the HTTP endpoint's 400.

#### Scenario: Creating a new folder

- **WHEN** a client calls `create_folder` with `path: "Ideas"`
- **THEN** the result SHALL have `structuredContent == { "path": "Ideas", "note_count": 0 }` and `isError` SHALL be absent or `false`

#### Scenario: Re-creating an existing folder succeeds

- **GIVEN** folder `Ideas` already exists
- **WHEN** a client calls `create_folder` with `path: "Ideas"` again
- **THEN** the result SHALL succeed with the same `structuredContent` shape, not an error

#### Scenario: Empty path is a validation error

- **WHEN** a client calls `create_folder` with `path: ""`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`
