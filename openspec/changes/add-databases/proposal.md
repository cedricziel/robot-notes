## Why

There is no way to say "these notes are projects, each has a status and a due date, show me the active ones as a board." Humans reach for Notion for that, and agents have no structured way to read or write per-note properties even though storage already round-trips arbitrary frontmatter. Databases add a typed, queryable layer over ordinary notes without abandoning the filesystem-is-the-database rule.

## What Changes

- A **database** is an ordinary note whose frontmatter carries `type: database`, a **source** (a folder, or a tag), a **properties** map (typed schema) and a list of named **views** (table, list, board), each with its own filter, sort, and grouping. Its markdown body is a free description.
- A **row** is any note matched by the source. Property values are top-level frontmatter keys on the row note, so files stay hand-editable.
- Property types in v1: `text`, `number`, `checkbox`, `date`, `select`, `multi_select`, `relation`, `url`. Built-in fields `title`, `path`, `tags`, `created_at`, `updated_at` are filterable and sortable like properties.
- New REST endpoints: list/get/create/update databases, query a database (filter, sort, group, paginate) by saved view or ad hoc, create a row, and `PATCH /notes/{id}/properties` which merges property changes without touching the body and without `If-Match`.
- `GET /notes/{id}`, `POST /notes`, and `PUT /notes/{id}` gain a `properties` field so full-note reads and writes carry frontmatter properties.
- Typed endpoints and tools reject schema violations (unknown select option, non-numeric number, reserved key). Hand-edited files are tolerated; offending values are reported as invalid, never dropped.
- New MCP tools: `list_databases`, `get_database`, `create_database`, `update_database`, `query_database`, `create_row`, `update_properties`. Existing `get_note`, `create_note`, `update_note` gain `properties`.
- The SQLite index gains property tables so queries run in SQL; the existing rebuild-from-content path handles migration.
- `relation` values are written as `[[Title]]` wikilinks and counted as outgoing links, so backlinks and rename propagation cover them.
- Property patches broadcast the existing `changed` event with `action: "updated"`.

## Capabilities

### New Capabilities

- `databases`: database definition notes, row membership, property types and validation, views, query semantics, row creation, and the property patch endpoint, over REST and MCP.

### Modified Capabilities

- `notes-api`: `GET /notes/{id}` returns `properties`; `POST /notes` and `PUT /notes/{id}` accept `properties`.
- `mcp-server`: tool catalog grows by the seven database tools; `get_note` returns `properties`; `create_note` and `update_note` accept `properties`.
- `notes-storage`: reserved frontmatter keys are defined; property values are stored as top-level frontmatter keys with a defined encoding per type.
- `links`: `relation` property values are parsed as outgoing links.
- `search`: the index stores property values and supports the database query path.

## Impact

- `server/lib/src/`: new `databases/` package, `storage.dart`, `note_write_service.dart`, `search_index.dart` (schema version 5), `links.dart`, `mcp/tools.dart`.
- `server/routes/databases/**`, `server/routes/notes/[id]/properties.dart`.
- `shared/lib/src/`: DTOs, route constants, error codes for the new endpoints.
- `server/API.md`, README tool catalog.
- No new external dependencies. Flutter client is a separate change (`add-database-views`).

## Non-goals

- No block editor, block references, or synced blocks.
- No formula, rollup, person, or file property types.
- No gallery or calendar views.
- No rendering of `![[Database#View]]` embeds; that is the app change.
- No Obsidian `.base` file compatibility.
