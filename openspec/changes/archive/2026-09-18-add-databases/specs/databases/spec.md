# Spec Delta

## Purpose

Lets a set of ordinary notes act as a typed, queryable collection: a definition note declares which notes are rows, what properties they carry, and how to view them, and both humans and agents read and write those properties through the API.

## ADDED Requirements

### Requirement: A database is a note with `type: database` frontmatter

A note SHALL be treated as a database definition when its frontmatter contains `type: database`. The definition SHALL carry `source` (an object with exactly one of `folder` or `tag`), `properties` (a map from property key to a property definition), and `views` (a non-empty list of view definitions). `source.folder` MAY be accompanied by `include_subfolders` (boolean, default `true`). When `source` is omitted the source SHALL default to the definition note's own folder with subfolders included. The definition note's markdown body is free text and SHALL NOT affect the schema. A note carrying `type: database` SHALL be excluded from every database's rows regardless of whether its definition validates. A definition whose frontmatter fails validation SHALL be logged naming the file, excluded from the database registry, and still served as an ordinary note.

#### Scenario: Definition note is recognised

- **GIVEN** a note `Projects.md` whose frontmatter contains `type: database`, a `properties` map and one view
- **WHEN** the server indexes the vault
- **THEN** `GET /databases` SHALL list that note's id and title

#### Scenario: Definition note is excluded from its own rows

- **GIVEN** a database whose source is folder `Projects` and whose definition note also lives in `Projects`
- **WHEN** the database is queried
- **THEN** the definition note SHALL NOT appear among the rows

#### Scenario: Source defaults to the definition's folder

- **GIVEN** a definition note at `Projects/Projects.md` with no `source` key
- **WHEN** the database is queried
- **THEN** every note under `Projects` and its subfolders, other than the definition, SHALL be a row

#### Scenario: Invalid definition is not registered

- **GIVEN** a note with `type: database` whose `properties` map contains an unknown property type
- **WHEN** the server indexes the vault
- **THEN** the server SHALL log an error naming the file, `GET /databases` SHALL NOT list it, and `GET /notes/{id}` SHALL still return the note

### Requirement: Property definitions have a key, a type, and type-specific options

Each entry in `properties` SHALL be keyed by a property key matching `^[a-z][a-z0-9_]*$`, at most 64 characters, and SHALL be an object with `type` set to one of `text`, `number`, `checkbox`, `date`, `select`, `multi_select`, `relation`, `url`. An optional `label` string SHALL be accepted for display. `select` and `multi_select` SHALL require `options`, a non-empty list of distinct non-empty strings. `relation` MAY carry `database` (the id of the database whose rows are valid targets); when omitted any note is a valid target. A typed write of a `relation` value whose target title resolves to a note that is not a row of the constrained database SHALL be rejected with `validation_failed`; an unresolved title SHALL be accepted (dangling links are allowed, as for body wikilinks). The keys `id`, `title`, `path`, `version`, `created_at`, `updated_at`, `type`, `tags`, `source`, `properties`, and `views` SHALL be reserved and rejected as property keys.

#### Scenario: Reserved key is rejected

- **WHEN** a client creates a database whose `properties` contains the key `version`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}` and a message naming the key

#### Scenario: Select without options is rejected

- **WHEN** a client creates a database with a `select` property lacking `options`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

#### Scenario: Unknown property type is rejected

- **WHEN** a client creates a database with a property of type `formula`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: Property values are encoded per type in row frontmatter

Property values SHALL be stored as top-level frontmatter keys on the row note using the property key as the frontmatter key. Encoding per type SHALL be: `text` a string; `number` a YAML integer or float; `checkbox` a YAML boolean; `date` a string `YYYY-MM-DD` or an ISO 8601 UTC timestamp; `select` one of the declared option strings; `multi_select` a list of declared option strings; `relation` a list of `[[Title]]` or `[[Title|Alias]]` wikilink strings; `url` a string that parses as an absolute `http` or `https` URL. A missing key SHALL mean the property is unset. `null` SHALL be treated as unset. A typed write (`POST /databases/{id}/rows`, `PATCH /notes/{id}/properties`, `properties` on `POST /notes` or `PUT /notes/{id}`, or the equivalent MCP tools) SHALL reject a value that does not satisfy the type or a key that is reserved. A property key not declared by any database whose source covers the note SHALL be accepted as free-form frontmatter without validation. A note matched by several databases SHALL be validated against every one of them. Validation SHALL apply only to values supplied by the caller of a typed write; server-internal rewrites (rename propagation, migrations) SHALL never validate and SHALL never fail because a file holds an invalid value.

#### Scenario: Select value outside options is rejected

- **GIVEN** a database with `status: {type: select, options: [Idea, Active, Done]}` over folder `Projects`
- **WHEN** a client calls `PATCH /notes/{id}/properties` on a note under `Projects` with `{"set":{"status":"Blocked"}}`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}` and the file SHALL be unchanged

#### Scenario: Number encoded as string is rejected

- **GIVEN** a database with `budget: {type: number}`
- **WHEN** a client sets `budget` to `"12"`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

#### Scenario: Undeclared key is accepted as free-form

- **GIVEN** a database over folder `Projects` declaring only `status`
- **WHEN** a client sets `mood: "great"` on a note under `Projects`
- **THEN** the write SHALL succeed and the frontmatter SHALL contain a `mood` key with string value `great`

#### Scenario: Relation is written as wikilinks

- **GIVEN** a database with `owner: {type: relation}`
- **WHEN** a client sets `owner` to `["[[Alice]]"]`
- **THEN** the row's frontmatter SHALL contain an `owner` key whose YAML value is a sequence with the single string item `[[Alice]]`

#### Scenario: Relation target outside the constrained database is rejected

- **GIVEN** `owner: {type: relation, database: <People id>}` and a note titled `Budget` that is not a row of People
- **WHEN** a client sets `owner` to `["[[Budget]]"]`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

#### Scenario: Internal rewrite tolerates an invalid stored value

- **GIVEN** a row has a hand-edited `status: Blocked` that is not an option, and its `owner` relation points at `Alice`
- **WHEN** the note `Alice` is renamed
- **THEN** the row's relation SHALL be rewritten and the row SHALL keep `status: Blocked`

#### Scenario: Hand-edited invalid value is reported, not dropped

- **GIVEN** a row file whose frontmatter contains `status: Blocked` where `Blocked` is not an option
- **WHEN** the database is queried
- **THEN** the row SHALL be returned with `properties.status` equal to `"Blocked"` and `invalid` containing `status`

### Requirement: Built-in fields behave as read-only properties

`title` (text), `path` (text), `tags` (multi-value text), `created_at` (date), and `updated_at` (date) SHALL be usable wherever a property key is accepted in a filter, sort, `group_by`, or view column list. They SHALL be rejected as targets of `PATCH /notes/{id}/properties`.

#### Scenario: Sorting by a built-in

- **GIVEN** a database with three rows updated at different times
- **WHEN** a client queries with `sort: [{"property":"updated_at","direction":"desc"}]`
- **THEN** rows SHALL be returned most recently updated first

#### Scenario: Patching a built-in is rejected

- **WHEN** a client calls `PATCH /notes/{id}/properties` with `{"set":{"title":"X"}}`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: Views are named and carry type, filter, sort, grouping, and columns

Each entry in `views` SHALL be an object with `name` (non-empty, unique within the database, case-insensitive) and `type` set to one of `table`, `list`, `board`. A view MAY carry `filter` (a filter expression), `sort` (a list of `{property, direction}` where `direction` is `asc` or `desc`), `group_by` (a property key), and `properties` (an ordered list of property keys to display). A `board` view SHALL require `group_by` naming a `select` property. The first view in the list SHALL be the default view.

#### Scenario: Board without group_by is rejected

- **WHEN** a client creates a database whose `views` contains `{name: Kanban, type: board}` with no `group_by`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

#### Scenario: Duplicate view names are rejected

- **WHEN** a client creates a database whose views are named `All` and `all`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: Filter expressions are structured, not free text

A filter expression SHALL be either a condition object `{property, op, value?}` or a combinator `{"and": [expr...]}` / `{"or": [expr...]}`, nested to any depth. `op` SHALL be one of `eq`, `neq`, `contains`, `not_contains`, `is_empty`, `is_not_empty`, `gt`, `gte`, `lt`, `lte`. `is_empty` and `is_not_empty` SHALL take no `value`. `contains` and `not_contains` SHALL apply to `text`, `url`, `multi_select`, `relation`, `tags`, and `title` (case-insensitive substring for text-like, membership for list-like). `gt`, `gte`, `lt`, `lte` SHALL apply to `number` and `date` (including `created_at` and `updated_at`). Every `date` value SHALL be normalised to a UTC instant plus its calendar day; `eq` and `neq` on `date` SHALL compare the calendar day, while `gt`, `gte`, `lt`, `lte` SHALL compare the instant, with a day-only right-hand value taken as `T00:00:00Z` for `gt`, `gte`, `lt` and as the end of that day for `lte`. `contains` case-insensitivity SHALL be ASCII-only. A missing key, `null`, an empty string, and an empty list SHALL all satisfy `is_empty`. A filter referencing an undeclared property or an operator not applicable to the property's type SHALL be rejected with `validation_failed`.

#### Scenario: Nested combinator

- **GIVEN** rows with statuses Idea, Active, Done and various due dates
- **WHEN** a client queries with `{"and":[{"property":"status","op":"neq","value":"Done"},{"or":[{"property":"due","op":"is_empty"},{"property":"due","op":"lte","value":"2026-12-31"}]}]}`
- **THEN** only rows that are not Done and are either undated or due on or before that day SHALL be returned

#### Scenario: Same-day timestamp satisfies a day-only lte

- **GIVEN** a row with `due: 2026-10-01T09:00:00Z`
- **WHEN** a client queries `{"property":"due","op":"lte","value":"2026-10-01"}`
- **THEN** the row SHALL be returned

#### Scenario: Empty list is empty

- **GIVEN** a row with `labels: []` for a `multi_select` property
- **WHEN** a client queries `{"property":"labels","op":"is_empty"}`
- **THEN** the row SHALL be returned

#### Scenario: Inapplicable operator is rejected

- **WHEN** a client queries with `{"property":"done","op":"gt","value":1}` where `done` is a `checkbox`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: Database endpoints expose definitions

`GET /databases` SHALL return `{items: [{id, title, path, source, row_count}]}` for every registered database. `GET /databases/{id}` SHALL return `{id, title, path, version, source, properties, views, created_at, updated_at}`. `POST /databases` SHALL accept `{title, path?, source?, properties, views, content?}` and create the definition note, returning the same shape as `GET /databases/{id}` with HTTP 201. `PUT /databases/{id}` SHALL accept `{source?, properties?, views?}` with an `If-Match` header equal to the note's current version, replacing each supplied section wholesale, and SHALL return the updated definition; a request without `If-Match` SHALL return HTTP 428 and a stale one HTTP 409 `{"error":"version_conflict"}`. `POST /databases` whose resolved file path collides with another note SHALL return HTTP 409 `{"error":"path_conflict"}`. `row_count` SHALL be the number of rows the default view would return without its filter, computed at request time. Deleting a definition note SHALL unregister the database so every `/databases/{id}` route returns 404 afterwards. Both writes SHALL validate the definition per the requirements above and SHALL go through the same note write path as any other note (version bump, `changed` broadcast, search and link indexing). Removing a property from `properties` SHALL NOT delete values from row files. An id that is not a registered database SHALL return HTTP 404 `{"error":"not_found"}` from every `/databases/{id}` route.

#### Scenario: Create a database

- **WHEN** a client posts `{"title":"Projects","source":{"folder":"Projects"},"properties":{"status":{"type":"select","options":["Idea","Active","Done"]}},"views":[{"name":"All","type":"table"}]}` to `/databases`
- **THEN** the response SHALL be HTTP 201, the file `<data-dir>/content/Projects.md` SHALL exist with `type: database` in its frontmatter, and `GET /databases` SHALL list it

#### Scenario: Update requires If-Match

- **GIVEN** a database at version 2
- **WHEN** a client sends `PUT /databases/{id}` with `If-Match: 1`
- **THEN** the response SHALL be HTTP 409 with `{"error":"version_conflict"}`

#### Scenario: Removing a property keeps row values

- **GIVEN** rows carry `budget` values and the definition declares `budget`
- **WHEN** the definition is updated without `budget`
- **THEN** the row files SHALL still contain their `budget` keys and queries SHALL no longer list `budget` in `properties` of the schema

#### Scenario: Update without If-Match

- **WHEN** a client sends `PUT /databases/{id}` with no `If-Match` header
- **THEN** the response SHALL be HTTP 428

#### Scenario: Create colliding with an existing note

- **GIVEN** a note titled `Projects` exists at vault root
- **WHEN** a client posts a database titled `Projects` with no path
- **THEN** the response SHALL be HTTP 409 with `{"error":"path_conflict"}`

#### Scenario: Deleted definition is unregistered

- **GIVEN** a registered database
- **WHEN** its definition note is deleted
- **THEN** `GET /databases/{id}` SHALL return HTTP 404 and `GET /databases` SHALL NOT list it

#### Scenario: Ordinary note id is not a database

- **WHEN** a client requests `GET /databases/{id}` for a note without `type: database`
- **THEN** the response SHALL be HTTP 404 with `{"error":"not_found"}`

### Requirement: Querying a database returns rows with properties

`POST /databases/{id}/query` SHALL accept `{view?, filter?, sort?, group_by?, limit?, after?}`. When `view` names a saved view, its `filter`, `sort`, and `group_by` SHALL apply unless the request supplies its own, in which case the request's value replaces that view field. When neither `view` nor a field is supplied, the default view's setting SHALL apply. `limit` SHALL default to 50 and SHALL be at most 200. The response SHALL be `{items: [{id, title, path, version, created_at, updated_at, tags, properties, invalid}], next_cursor, groups?}` where `properties` contains every declared property present on the row (undeclared frontmatter keys SHALL be omitted), `invalid` lists declared keys whose stored value fails the type, and `groups`, present only when a `group_by` is in effect, is a list of `{value, count}` over the whole filtered set (with `value: null` for rows lacking the property) in option order. Sort SHALL be stable with `id` ascending as the final tie-break; unset values SHALL sort last for both directions; when no sort is in effect the order SHALL be `id` ascending. When `group_by` names a `select` property, groups SHALL follow option order with `count: 0` for unused options; for any other property, groups SHALL be the distinct values present in ascending order; in both cases a trailing `null` bucket follows. Each item SHALL be `{id, title, path, version, created_at, updated_at, tags, properties, invalid}` and SHALL NOT include `content`. `after` SHALL be an opaque cursor from a previous page that encodes the sort in effect; a cursor produced under a different sort SHALL be rejected with HTTP 400. Rows SHALL reflect the last committed write at query time.

#### Scenario: Query a saved view

- **GIVEN** a view `Active` with filter `status neq Done` and sort `due asc`
- **WHEN** a client posts `{"view":"Active"}`
- **THEN** items SHALL exclude Done rows and be ordered by `due` ascending with undated rows last

#### Scenario: Request filter overrides the view filter

- **GIVEN** the same view `Active`
- **WHEN** a client posts `{"view":"Active","filter":{"property":"status","op":"eq","value":"Done"}}`
- **THEN** items SHALL contain only Done rows, still sorted by `due` ascending

#### Scenario: Grouped query returns group counts

- **GIVEN** a board view grouped by `status` and rows with 2 Idea, 3 Active, 0 Done, and 1 without status
- **WHEN** a client posts `{"view":"Kanban"}`
- **THEN** `groups` SHALL equal `[{"value":"Idea","count":2},{"value":"Active","count":3},{"value":"Done","count":0},{"value":null,"count":1}]`

#### Scenario: Pagination

- **GIVEN** 120 rows
- **WHEN** a client posts `{"limit":50}` and then `{"limit":50,"after":"<next_cursor>"}` twice
- **THEN** the three pages SHALL contain 50, 50, and 20 distinct rows and the last `next_cursor` SHALL be null

#### Scenario: Tag source

- **GIVEN** a database with `source: {tag: project}`
- **WHEN** it is queried
- **THEN** every note carrying tag `project` (frontmatter or inline) other than database definitions SHALL be a row regardless of folder

#### Scenario: Unknown view name

- **WHEN** a client posts `{"view":"Nope"}`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: Creating a row creates a note with validated properties

`POST /databases/{id}/rows` SHALL accept `{title, properties?, content?, path?}` and create a note. For a folder source, `path` SHALL default to `source.folder` and SHALL be rejected with `validation_failed` when it is neither that folder nor nested under it (or equal to it when `include_subfolders` is false). For a tag source, `path` SHALL default to the vault root and the server SHALL add the source tag to the note's frontmatter `tags`. Properties SHALL be validated against the definition before anything is written. The response SHALL be HTTP 201 with the full note record `{id, title, path, content, version, created_at, updated_at, tags, properties}` as returned by `GET /notes/{id}`.

#### Scenario: Row lands in the source folder

- **GIVEN** a database over folder `Projects`
- **WHEN** a client posts `{"title":"Rewrite","properties":{"status":"Idea"}}` to `/databases/{id}/rows`
- **THEN** the file `<data-dir>/content/Projects/Rewrite.md` SHALL exist with a frontmatter `status` key whose YAML value is the string `Idea`

#### Scenario: Row for a tag source gets the tag

- **GIVEN** a database with `source: {tag: project}`
- **WHEN** a client creates a row
- **THEN** the new note's frontmatter `tags` SHALL include `project`

#### Scenario: Path outside the source is rejected

- **GIVEN** a database over folder `Projects`
- **WHEN** a client posts a row with `path: "Archive"`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}` and no file SHALL be created

### Requirement: Property patches merge without If-Match and without touching the body

`PATCH /notes/{id}/properties` SHALL accept `{set?: {key: value}, unset?: [key]}` with at least one of the two non-empty. It SHALL rewrite only the named frontmatter keys, preserving the body byte-for-byte and every other frontmatter key, SHALL NOT require `If-Match`, SHALL increment `version`, update `updated_at`, and SHALL return the same shape as `GET /notes/{id}`. It SHALL NOT be blocked by another actor's editor lock. It SHALL be serialised with every other write to the same note so that it always applies on top of the latest committed version and a concurrent body write with a stale `If-Match` is the one rejected. It SHALL broadcast a `changed` event with `action: "updated"`. Validation failures SHALL leave the file untouched. A key appearing in both `set` and `unset` SHALL be rejected.

#### Scenario: Patch preserves body and other keys

- **GIVEN** a note at version 3 with body `Hello` and frontmatter keys `status: Idea` and `mood: great`
- **WHEN** a client sends `{"set":{"status":"Active"},"unset":["mood"]}`
- **THEN** the file SHALL have a `status` key with string value `Active`, no `mood` key, body `Hello`, `version: 4`, and the response `version` SHALL be 4

#### Scenario: Patch ignores the editor lock

- **GIVEN** actor `alice` holds the editor lock on a note
- **WHEN** actor `bob` patches a property on it
- **THEN** the response SHALL be HTTP 200 and a `changed` event with `by: "bob"` and `action: "updated"` SHALL be broadcast

#### Scenario: Patch does not race a concurrent body edit

- **GIVEN** a note at version 3
- **WHEN** a property patch and a `PUT` with `If-Match: 3` arrive concurrently
- **THEN** one of them SHALL be applied first, the `PUT` SHALL either succeed at version 4 (if first) or be rejected with `version_conflict` (if second), and the patched property SHALL be present in the file in either case where the patch succeeded

#### Scenario: Empty patch is rejected

- **WHEN** a client sends `{}`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

### Requirement: MCP tools mirror the database endpoints

The MCP tool catalog SHALL include `list_databases` (no inputs), `get_database` (`id` required), `create_database` (`title` required; `path`, `source`, `properties`, `views`, `content`), `update_database` (`id` and `version` required; `source`, `properties`, `views`), `query_database` (`id` required; `view`, `filter`, `sort`, `group_by`, `limit` integer 1..200, `after`), `create_row` (`id` and `title` required; `properties`, `content`, `path`), and `update_properties` (`id` required; `set`, `unset`). Each SHALL return the same structured content as the corresponding HTTP endpoint, with HTTP error codes mapped to the same tool error codes (`not_found`, `validation_failed`, `version_conflict`, `path_conflict`). `create_database`, `update_database`, `create_row`, and `update_properties` SHALL require the write scope; `list_databases`, `get_database`, and `query_database` SHALL be available with the read scope. `update_properties` SHALL ignore the editor lock exactly as `PATCH /notes/{id}/properties` does. An argument of the wrong JSON type (for example `filter` given as a string) SHALL be an invalid-params JSON-RPC error, never an internal error. Tool descriptions SHALL state the property key rules, the value encoding per type, and the filter grammar so an agent can call them without reading external documentation.

#### Scenario: Agent discovers the schema

- **WHEN** a client calls `get_database` with a valid id
- **THEN** `structuredContent.properties` SHALL list every property with its `type` and, for selects, `options`

#### Scenario: Agent creates a row with an invalid option

- **WHEN** a client calls `create_row` with `properties: {status: "Blocked"}` where `Blocked` is not an option
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`

#### Scenario: Agent patches a property

- **WHEN** a client calls `update_properties` with `set: {status: "Done"}` on a row
- **THEN** the result SHALL contain the note with `properties.status == "Done"` and a `changed` event SHALL be broadcast

#### Scenario: Read scope can query

- **WHEN** a client whose credential has only the read scope calls `query_database`
- **THEN** the result SHALL be the query page, not a permission error

#### Scenario: Wrong argument type is invalid params

- **WHEN** a client calls `query_database` with `filter: "status=done"`
- **THEN** the response SHALL be a JSON-RPC invalid-params error

#### Scenario: Read-only scope cannot create a database

- **WHEN** a client whose credential lacks the write scope calls `create_database`
- **THEN** the result SHALL be a permission tool error identical to the one `create_note` returns for that credential

### Requirement: Property values are indexed and queries reflect every write

The server SHALL index property values for every note on startup and on every write so that `POST /databases/{id}/query` never reads row files during a request. A definition change (new source, new properties) SHALL take effect on the next query without a restart. A note moved out of a folder source or losing a source tag SHALL stop being a row on the next query.

#### Scenario: Moved note leaves the database

- **GIVEN** a note under `Projects` is a row
- **WHEN** it is moved to `Archive`
- **THEN** the next query SHALL NOT include it

#### Scenario: Source change takes effect immediately

- **GIVEN** a database over folder `Projects`
- **WHEN** its source is changed to `{tag: project}`
- **THEN** the next query SHALL return the tagged notes and not the folder's untagged notes
