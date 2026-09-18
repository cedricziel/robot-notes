# Spec Delta

## MODIFIED Requirements

### Requirement: GET /notes/{id} returns the full note

`GET /notes/{id}` SHALL return a JSON body with `id`, `title`, `path`, `content`, `version`, `created_at`, `updated_at`, `tags`, `properties`, and an optional `lock` object. `properties` SHALL be a JSON object containing every frontmatter key other than the reserved keys `id`, `title`, `path`, `version`, `created_at`, `updated_at`, `type`, `tags`, `source`, `properties`, and `views`, with values encoded as JSON (strings, numbers, booleans, lists, objects). When the note is a database definition, the body SHALL additionally contain `type: "database"`. When the note is currently locked, `lock` SHALL contain `holder` (string) and `expires_at` (ISO 8601). When unlocked, `lock` SHALL be omitted or `null`. Unknown ids SHALL return HTTP 404.

#### Scenario: Existing note is returned with all fields

- **GIVEN** a note exists at id `01HXY...ABC`
- **WHEN** an authenticated client requests `GET /notes/01HXY...ABC`
- **THEN** the response SHALL be 200 with body containing `id`, `title`, `path`, `content`, `version`, `created_at`, `updated_at`, `tags`, `properties`

#### Scenario: Frontmatter extras are exposed as properties

- **GIVEN** a note file whose frontmatter contains `status: Active` and `due: 2026-10-01`
- **WHEN** a client requests the note
- **THEN** `properties` SHALL equal `{"status":"Active","due":"2026-10-01"}`

#### Scenario: Locked note includes lock metadata

- **GIVEN** a note is currently locked by actor `alice` until `2026-04-25T12:00:00Z`
- **WHEN** any client requests the note
- **THEN** the response body SHALL include `"lock": {"holder":"alice","expires_at":"2026-04-25T12:00:00Z"}`

#### Scenario: Unknown id returns 404

- **WHEN** a client requests `GET /notes/01HXY...XXX` for an id with no corresponding file
- **THEN** the response SHALL have status 404 and a JSON body `{"error":"not_found"}`

### Requirement: POST /notes creates a new note

`POST /notes` SHALL accept a JSON body with `title` (required, non-empty string), `content` (optional, defaults to empty string), `path` (optional, defaults to the empty string / vault root), and `properties` (optional JSON object). The server SHALL generate a ULID, write the file with `version: 1` at the resolved folder and sanitized title, including each `properties` entry as a top-level frontmatter key, and return HTTP 201 with the full note record in the same shape as `GET /notes/{id}`. If the resolved target path already belongs to another note, the server SHALL return HTTP 409 with `{"error":"path_conflict"}`. A `properties` object containing a reserved key SHALL be rejected with HTTP 400 `{"error":"validation_failed"}`. Property values SHALL be validated against every database whose source covers the new note, per the `databases` capability.

#### Scenario: Successful creation returns 201 and full record

- **WHEN** a client posts `{"title":"Meeting","content":"# Hello"}`
- **THEN** the response SHALL have status 201 and body containing `id`, `title`, `path`, `content`, `version: 1`, `created_at`, `updated_at`, `properties`

#### Scenario: Creation with a path places the note in that folder

- **WHEN** a client posts `{"title":"Meeting","path":"Projects/Alpha"}`
- **THEN** the response body SHALL contain `path: "Projects/Alpha"` and the file SHALL be written under that folder

#### Scenario: Properties are written to frontmatter

- **WHEN** a client posts `{"title":"Hello","properties":{"status":"Idea"}}`
- **THEN** the created file's frontmatter SHALL contain `status: Idea` and the response `properties` SHALL equal `{"status":"Idea"}`

#### Scenario: Reserved property key is rejected

- **WHEN** a client posts `{"title":"Hello","properties":{"version":9}}`
- **THEN** the response SHALL be HTTP 400 with `{"error":"validation_failed"}`

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

### Requirement: PUT /notes/{id} requires If-Match and uses optimistic concurrency

`PUT /notes/{id}` SHALL accept a JSON body with any of `title`, `content`, `path`, and `properties`. The request SHALL include an `If-Match: <version>` header. The server SHALL accept the update only when the supplied version equals the current version. When `title` or `path` changes, the server SHALL rename or move the underlying file (per `notes-storage`) as part of the same write. When `properties` is supplied it SHALL replace the note's entire non-reserved frontmatter set (keys absent from the object are removed) after validation per the `databases` capability; when omitted, existing frontmatter extras SHALL be preserved unchanged. On success the server SHALL return HTTP 200 with the new full note record (including the incremented `version`). On version mismatch the server SHALL return HTTP 409 with the current state. If the change would collide with another note's path, the server SHALL return HTTP 409 with `{"error":"path_conflict"}` instead of applying any part of the write.

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

#### Scenario: Omitted properties preserves extras

- **GIVEN** a note whose frontmatter contains `status: Active`
- **WHEN** a client sends `PUT` with only `title` and `content`
- **THEN** the saved file SHALL still contain `status: Active`

#### Scenario: Supplied properties replace extras

- **GIVEN** a note whose frontmatter contains `status: Active` and `mood: great`
- **WHEN** a client sends `PUT` with `properties: {"status":"Done"}`
- **THEN** the saved file SHALL contain `status: Done` and no `mood` key

#### Scenario: Changing path moves the note and returns the new path

- **GIVEN** a note at version 5 with path `""`
- **WHEN** a client sends `PUT /notes/{id}` with `If-Match: 5` and body `{"path":"Projects/Alpha"}`
- **THEN** the response SHALL be 200 with `version: 6` and `path: "Projects/Alpha"`, and the file SHALL be moved on disk

#### Scenario: Move colliding with an existing note is rejected

- **GIVEN** a note already exists at `Projects/Alpha/Notes.md`
- **WHEN** a different note titled `Notes` is moved to path `Projects/Alpha`
- **THEN** the response SHALL be 409 with `{"error":"path_conflict"}` and neither file SHALL be changed
