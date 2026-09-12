## MODIFIED Requirements

### Requirement: GET /notes returns paginated metadata

`GET /notes` SHALL return a JSON object containing `items` (an array of note metadata) and `next_cursor` (a string or null). Each item SHALL contain `id`, `title`, `path`, `version`, `updated_at`, and `created_at`. The endpoint SHALL accept `limit` (default 50, max 200), `after`, `sort`, `path` (return only notes whose `path` equals or is nested under the given folder), and `tag` (return only notes carrying the given tag) query parameters. `after` is an opaque cursor derived from the last item of the previous page. `path` and `tag` MAY be combined with either `sort` value and with each other; they narrow the result set before pagination is applied. Item content SHALL NOT be included.

`sort` SHALL be one of:

- `id` (default) — ascending by `id`, preserved for backward compatibility. The cursor is the last item's plain `id`.
- `updated_desc` — descending by `updated_at`, ties broken by `id` descending, so pagination stays stable while notes are created or edited. The cursor is an opaque string encoding both `updated_at` and `id`.

Any other `sort` value SHALL be rejected with HTTP 400. A cursor that cannot be decoded for the requested `sort` SHALL also be rejected with HTTP 400.

#### Scenario: Default page size is 50

- **GIVEN** the server holds 100 notes
- **WHEN** a client requests `GET /notes` with no query parameters
- **THEN** the response SHALL contain `items` of length 50 and a non-null `next_cursor`

#### Scenario: Cursor pagination returns the next page

- **GIVEN** a previous response returned `next_cursor: "<c>"`
- **WHEN** the client requests `GET /notes?after=<c>`
- **THEN** the response SHALL contain the next page of notes in id-sorted order

#### Scenario: Last page has null next_cursor

- **WHEN** the page returned is the final page
- **THEN** `next_cursor` SHALL be `null`

#### Scenario: Items contain metadata only, no content

- **WHEN** a client requests `GET /notes`
- **THEN** items SHALL NOT contain a `content` field

#### Scenario: sort=updated_desc orders by most recently updated first

- **GIVEN** note A was last updated before note B
- **WHEN** a client requests `GET /notes?sort=updated_desc`
- **THEN** note B SHALL appear before note A in `items`

#### Scenario: sort=updated_desc paginates with an opaque cursor

- **GIVEN** a previous `GET /notes?sort=updated_desc` response returned `next_cursor: "<c>"`
- **WHEN** the client requests `GET /notes?sort=updated_desc&after=<c>`
- **THEN** the response SHALL contain the next page in `updated_at`-descending order

#### Scenario: Unknown sort value is rejected

- **WHEN** a client requests `GET /notes?sort=bogus`
- **THEN** the response SHALL have status 400 and a JSON body `{"error":"bad_request"}`

#### Scenario: Path filter returns only notes under that folder

- **GIVEN** notes exist at `Projects/Alpha/A`, `Projects/Beta/B`, and vault root `C`
- **WHEN** a client requests `GET /notes?path=Projects/Alpha`
- **THEN** `items` SHALL contain only `A`

#### Scenario: Tag filter returns only notes carrying that tag

- **GIVEN** two notes carry tag `urgent` and a third does not
- **WHEN** a client requests `GET /notes?tag=urgent`
- **THEN** `items` SHALL contain exactly the two tagged notes

#### Scenario: Path filter composes with sort=updated_desc

- **GIVEN** two notes under `Projects/Alpha` were updated at different times, and a third, more recently updated note sits at vault root
- **WHEN** a client requests `GET /notes?path=Projects/Alpha&sort=updated_desc`
- **THEN** `items` SHALL contain only the two notes under `Projects/Alpha`, most-recently-updated first

### Requirement: POST /notes creates a new note

`POST /notes` SHALL accept a JSON body with `title` (required, non-empty string), `content` (optional, defaults to empty string), and `path` (optional, defaults to the empty string / vault root). The server SHALL generate a ULID, write the file with `version: 1` at the resolved folder and sanitized title, and return HTTP 201 with the full note record. If the resolved target path already belongs to another note, the server SHALL return HTTP 409 with `{"error":"path_conflict"}`.

#### Scenario: Successful creation returns 201 and full record

- **WHEN** a client posts `{"title":"Meeting","content":"# Hello"}`
- **THEN** the response SHALL have status 201 and body containing `id`, `title`, `path`, `content`, `version: 1`, `created_at`, `updated_at`

#### Scenario: Creation with a path places the note in that folder

- **WHEN** a client posts `{"title":"Meeting","path":"Projects/Alpha"}`
- **THEN** the response body SHALL contain `path: "Projects/Alpha"` and the file SHALL be written under that folder

#### Scenario: Missing title is rejected

- **WHEN** a client posts `{"content":"hi"}`
- **THEN** the response SHALL have status 400 and a JSON body with an `error` field describing the missing field

#### Scenario: Empty title is rejected

- **WHEN** a client posts `{"title":"","content":"hi"}`
- **THEN** the response SHALL have status 400

#### Scenario: Title colliding with an existing note in the same folder is rejected

- **GIVEN** a note titled `Ideas` already exists at vault root
- **WHEN** a client posts `{"title":"Ideas"}` with no path
- **THEN** the response SHALL have status 409 with body `{"error":"path_conflict"}`

### Requirement: GET /notes/{id} returns the full note

`GET /notes/{id}` SHALL return a JSON body with `id`, `title`, `path`, `content`, `version`, `created_at`, `updated_at`, and an optional `lock` object. When the note is currently locked, `lock` SHALL contain `holder` (string) and `expires_at` (ISO 8601). When unlocked, `lock` SHALL be omitted or `null`. Unknown ids SHALL return HTTP 404.

#### Scenario: Existing note is returned with all fields

- **GIVEN** a note exists at id `01HXY...ABC`
- **WHEN** an authenticated client requests `GET /notes/01HXY...ABC`
- **THEN** the response SHALL be 200 with body containing `id`, `title`, `path`, `content`, `version`, `created_at`, `updated_at`

#### Scenario: Locked note includes lock metadata

- **GIVEN** a note is currently locked by actor `alice` until `2026-04-25T12:00:00Z`
- **WHEN** any client requests the note
- **THEN** the response body SHALL include `"lock": {"holder":"alice","expires_at":"2026-04-25T12:00:00Z"}`

#### Scenario: Unknown id returns 404

- **WHEN** a client requests `GET /notes/01HXY...XXX` for an id with no corresponding file
- **THEN** the response SHALL have status 404 and a JSON body `{"error":"not_found"}`

### Requirement: PUT /notes/{id} requires If-Match and uses optimistic concurrency

`PUT /notes/{id}` SHALL accept a JSON body with any of `title`, `content`, and `path`. The request SHALL include an `If-Match: <version>` header. The server SHALL accept the update only when the supplied version equals the current version. When `title` or `path` changes, the server SHALL rename or move the underlying file (per `notes-storage`) as part of the same write. On success the server SHALL return HTTP 200 with the new full note record (including the incremented `version`). On version mismatch the server SHALL return HTTP 409 with the current state. If the change would collide with another note's path, the server SHALL return HTTP 409 with `{"error":"path_conflict"}` instead of applying any part of the write.

#### Scenario: Update with matching If-Match succeeds

- **GIVEN** a note at version 5 with no active lock
- **WHEN** an authenticated client sends `PUT /notes/{id}` with header `If-Match: 5` and a valid body
- **THEN** the response SHALL be 200 with `version: 6` and the updated content

#### Scenario: Update with stale If-Match returns 409 with current state

- **GIVEN** a note at current version 7
- **WHEN** a client sends `PUT /notes/{id}` with header `If-Match: 5`
- **THEN** the response SHALL be 409 with body `{ "error":"version_conflict", "current_version":7, "current_content":"...", "current_title":"..." }`

#### Scenario: Missing If-Match header is rejected

- **WHEN** a client sends `PUT /notes/{id}` without an `If-Match` header
- **THEN** the response SHALL be 428 (Precondition Required)

#### Scenario: Non-numeric If-Match is rejected

- **WHEN** a client sends `PUT /notes/{id}` with `If-Match: abc`
- **THEN** the response SHALL be 400

#### Scenario: Update preserves frontmatter unknown keys

- **GIVEN** a note whose frontmatter has an extra `tags: [x]` key
- **WHEN** the note is updated
- **THEN** the file on disk SHALL still contain `tags: [x]`

#### Scenario: Changing path moves the note and returns the new path

- **GIVEN** a note at version 5 with path `""`
- **WHEN** a client sends `PUT /notes/{id}` with `If-Match: 5` and body `{"path":"Projects/Alpha"}`
- **THEN** the response SHALL be 200 with `version: 6` and `path: "Projects/Alpha"`, and the file SHALL be moved on disk

#### Scenario: Move colliding with an existing note is rejected

- **GIVEN** a note already exists at `Projects/Alpha/Notes.md`
- **WHEN** a different note titled `Notes` is moved to path `Projects/Alpha`
- **THEN** the response SHALL be 409 with `{"error":"path_conflict"}` and neither file SHALL be changed

### Requirement: Successful writes broadcast a `changed` event

Every successful POST, PUT, or DELETE on a note SHALL trigger a `changed` event broadcast over the realtime channel (see `realtime-sync` capability). The broadcast SHALL include the note id, the new version (or `null` for delete), the actor identity, and the action (`created`, `updated`, `moved`, `deleted`). A PUT that changes `path` (with or without other field changes) SHALL broadcast action `moved`. The broadcast SHALL be best-effort: failure to broadcast SHALL NOT roll back the on-disk write.

#### Scenario: Update broadcasts version 6

- **GIVEN** a note moves from version 5 to 6 with no path change
- **WHEN** the PUT response is returned
- **THEN** all subscribed WS clients SHALL receive `{"type":"changed","note_id":"...","version":6,"by":"alice","action":"updated"}`

#### Scenario: Path change broadcasts a moved action

- **GIVEN** a note's path changes as part of a PUT
- **WHEN** the PUT response is returned
- **THEN** subscribed WS clients SHALL receive a `changed` event with `action: "moved"`

#### Scenario: Delete broadcasts deletion

- **GIVEN** a note is deleted
- **THEN** subscribed clients SHALL receive `{"type":"changed","note_id":"...","version":null,"by":"alice","action":"deleted"}`

## ADDED Requirements

### Requirement: GET /notes/tree returns the folder hierarchy

`GET /notes/tree` SHALL return a JSON object describing the vault's folder structure without paginating individual notes: `{ folders: [{ path, note_count }] }`, one entry per distinct folder that directly contains at least one note, sorted by path. `note_count` SHALL count only notes directly in that folder, not in its subfolders. An intermediate folder that holds no notes of its own but has a descendant folder that does (e.g. `Projects` when only `Projects/Alpha` has notes) SHALL NOT get its own entry; clients that want an aggregate count or need to render intermediate tree nodes SHALL derive them from the listed leaf paths. The endpoint SHALL require authentication.

#### Scenario: Tree lists folders with notes

- **GIVEN** notes exist at vault root, `Projects/Alpha`, and `Projects/Beta`
- **WHEN** a client requests `GET /notes/tree`
- **THEN** the response SHALL contain folder entries for `""`, `Projects/Alpha`, and `Projects/Beta` with their respective note counts

#### Scenario: Folder with no notes is not listed

- **GIVEN** an empty directory exists on disk with no note files in it
- **WHEN** a client requests `GET /notes/tree`
- **THEN** that folder SHALL NOT appear in `folders`

### Requirement: GET /tags returns all tags with counts

`GET /tags` SHALL return `{ items: [{ tag, count }] }` listing every distinct tag across all notes (merging frontmatter `tags` and inline `#tag` tokens, per `notes-storage`), sorted by descending count. The endpoint SHALL require authentication.

#### Scenario: Tags are listed with counts

- **GIVEN** three notes carry tag `urgent` and one carries `later`
- **WHEN** a client requests `GET /tags`
- **THEN** the response SHALL contain `{"tag":"urgent","count":3}` before `{"tag":"later","count":1}`
