# Spec Delta

## MODIFIED Requirements

### Requirement: tools/list returns the fixed note tool catalog

`tools/list` SHALL return exactly these tools, each with a `description` and a JSON Schema `inputSchema` of type `object` declaring the listed properties and `required` set: `list_notes` (`limit` integer 1..200, `after` string, `path` string, `tag` string), `get_note` (`id` required), `create_note` (`title` required, `content`, `path`, `properties` object), `update_note` (`id` and `version` required, `title`, `content`, `path`, `properties` object), `append_to_note` (`id` and `text` required), `delete_note` (`id` required), `search_notes` (`query` required, `limit` integer 1..100, `path` string, `tag` string), `move_note` (`id` and `version` required, `path` required), `get_backlinks` (`id` required), `create_folder` (`path` required), `request_upload` and `finalize_upload` (as specified by the file upload capability), `list_databases` (no inputs), `get_database` (`id` required), `create_database` (`title` required; `path`, `source`, `properties`, `views`, `content`), `update_database` (`id` and `version` required; `source`, `properties`, `views`), `query_database` (`id` required; `view`, `filter`, `sort`, `group_by`, `limit` integer 1..200, `after`), `create_row` (`id` and `title` required; `properties`, `content`, `path`), `update_properties` (`id` required; `set` object, `unset` array). The catalog SHALL be the same regardless of the caller's scopes. The result SHALL NOT include a `nextCursor`.

#### Scenario: Catalog contents

- **WHEN** an authenticated client sends `tools/list`
- **THEN** the result `tools` array SHALL contain exactly the nineteen names above, each with `inputSchema.type == "object"`

#### Scenario: Required fields are declared

- **WHEN** the client inspects the `update_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version"]`

#### Scenario: move_note requires id, version, and path

- **WHEN** the client inspects the `move_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version", "path"]`

#### Scenario: create_row requires id and title

- **WHEN** the client inspects the `create_row` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "title"]`

### Requirement: Read tools mirror the HTTP API

`list_notes` SHALL return `{ items: [{ id, title, path, version, created_at, updated_at }], next_cursor }` following the same pagination, `path`, and `tag` filter rules as `GET /notes` (`limit` defaults to 50; values outside 1..200 are rejected as invalid params). `get_note` SHALL return `{ id, title, path, content, version, created_at, updated_at, tags, properties, lock? }` with `properties` as defined for `GET /notes/{id}` and `lock` present only while an editor lock is active. `search_notes` SHALL return `{ items: [{ id, title, path, snippet, rank }] }` using the same ranking, snippet markup, `path`/`tag` filters, and default limit (20) as `GET /search`; an empty or FTS-invalid `query` SHALL be a `validation_failed` tool error. `get_backlinks` SHALL return `{ items: [{ id, title, snippet }] }` identical to `GET /notes/{id}/backlinks`, with an unknown `id` returning a `not_found` tool error.

#### Scenario: Pagination cursor

- **WHEN** 3 notes exist and a client calls `list_notes` with `limit: 2`
- **THEN** the result SHALL contain 2 items and a non-null `next_cursor`, and calling again with `after: next_cursor` SHALL return the remaining note

#### Scenario: Search hit

- **WHEN** a note containing the word "budget" exists and a client calls `search_notes` with `query: "budget"`
- **THEN** the result `items` SHALL contain that note's id with a `snippet` containing `<mark>budget</mark>`

#### Scenario: Invalid search query

- **WHEN** a client calls `search_notes` with `query: "   "`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`

#### Scenario: list_notes honors the path filter

- **GIVEN** notes exist both under `Projects/Alpha` and at vault root
- **WHEN** a client calls `list_notes` with `path: "Projects/Alpha"`
- **THEN** the result `items` SHALL contain only notes under that folder

#### Scenario: get_backlinks returns referencing notes

- **GIVEN** note B links to note A
- **WHEN** a client calls `get_backlinks` with `id: A`
- **THEN** the result `items` SHALL contain note B

#### Scenario: get_note exposes properties

- **GIVEN** a note whose frontmatter contains `status: Active`
- **WHEN** a client calls `get_note` with its id
- **THEN** `structuredContent.properties.status` SHALL equal `"Active"`

### Requirement: Write tools enforce optimistic concurrency, locks, and broadcast changes

`create_note` SHALL create a note (empty `title` is a `validation_failed` tool error) at the given `path` (defaulting to vault root), writing any `properties` as frontmatter keys under the same validation rules as `POST /notes`, and return the full note. `update_note` SHALL require `version` to equal the note's current version; on mismatch it SHALL return a `version_conflict` tool error whose `structuredContent` includes `current_version` and `current_content`; at least one of `title`, `content`, `path`, or `properties` SHALL be supplied, otherwise `validation_failed`; a `path` change SHALL move the note as in `PUT /notes/{id}`; a supplied `properties` object SHALL replace the note's non-reserved frontmatter as in `PUT /notes/{id}`. `move_note` SHALL change only a note's `path` under the same version-check and lock rules as `update_note`, returning the full note record. If the resolved target path collides with a different note, `create_note`, `update_note`, and `move_note` SHALL return a `path_conflict` tool error. `delete_note` SHALL remove the note and return `{ id, deleted: true }`. `update_note`, `move_note`, `append_to_note`, and `delete_note` SHALL return a `locked` tool error with the current `holder` when another actor holds the editor lock. Every successful write SHALL broadcast the same `changed` event as the equivalent HTTP call (including `action: "moved"` for a path change), with `by` set to the MCP actor.

#### Scenario: Update with stale version

- **WHEN** a note is at version 3 and a client calls `update_note` with `version: 2`
- **THEN** the result SHALL have `isError == true`, `structuredContent.error == "version_conflict"`, and `structuredContent.current_version == 3`

#### Scenario: Update succeeds

- **WHEN** a note is at version 3 and a client calls `update_note` with `version: 3` and `content: "new"`
- **THEN** the result SHALL contain `version: 4` and a `changed` event with `action: "updated"` SHALL be broadcast

#### Scenario: Update with only properties

- **WHEN** a note is at version 3 and a client calls `update_note` with `version: 3` and `properties: {"status":"Done"}`
- **THEN** the result SHALL contain `version: 4` and `properties.status == "Done"` with the body unchanged

#### Scenario: Locked by another actor

- **WHEN** actor `alice` holds the lock on a note and an MCP client acting as `bob` calls `delete_note` on it
- **THEN** the result SHALL have `isError == true`, `structuredContent.error == "locked"`, and `structuredContent.holder == "alice"`

#### Scenario: Delete broadcasts

- **WHEN** a client calls `delete_note` on an unlocked note
- **THEN** the result SHALL be `{ id, deleted: true }` and a `changed` event with `action: "deleted"` SHALL be broadcast

#### Scenario: move_note relocates the note and broadcasts moved

- **WHEN** a note is at version 3 and a client calls `move_note` with `version: 3` and `path: "Projects/Alpha"`
- **THEN** the result SHALL contain `version: 4` and `path: "Projects/Alpha"`, and a `changed` event with `action: "moved"` SHALL be broadcast

#### Scenario: move_note colliding with another note is a tool error

- **GIVEN** a note already exists at `Projects/Alpha/Notes.md`
- **WHEN** a client calls `move_note` to relocate a differently-titled-but-colliding note into `Projects/Alpha`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "path_conflict"`
