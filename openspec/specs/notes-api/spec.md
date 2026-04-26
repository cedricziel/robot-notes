# notes-api Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Server exposes RESTful note CRUD endpoints

The server SHALL expose the following endpoints rooted at `/notes`:

- `GET /notes` — list notes
- `POST /notes` — create a note
- `GET /notes/{id}` — read a note
- `PUT /notes/{id}` — update a note (requires `If-Match`)
- `DELETE /notes/{id}` — delete a note

All endpoints SHALL accept and return `application/json`. All endpoints SHALL require authentication per the `auth` capability.

#### Scenario: All five endpoints are routable

- **WHEN** an authenticated client issues each of GET `/notes`, POST `/notes`, GET `/notes/{id}`, PUT `/notes/{id}`, and DELETE `/notes/{id}`
- **THEN** each request SHALL be matched by a route handler (i.e. SHALL NOT return 404 due to missing route)

### Requirement: GET /notes returns paginated metadata

`GET /notes` SHALL return a JSON object containing `items` (an array of note metadata) and `next_cursor` (a string or null). Each item SHALL contain `id`, `title`, `version`, `updated_at`, and `created_at`. The endpoint SHALL accept `limit` (default 50, max 200) and `cursor` query parameters, with the cursor being an opaque string derived from the last item's id. Item content SHALL NOT be included.

#### Scenario: Default page size is 50

- **GIVEN** the server holds 100 notes
- **WHEN** a client requests `GET /notes` with no query parameters
- **THEN** the response SHALL contain `items` of length 50 and a non-null `next_cursor`

#### Scenario: Cursor pagination returns the next page

- **GIVEN** a previous response returned `next_cursor: "<c>"`
- **WHEN** the client requests `GET /notes?cursor=<c>`
- **THEN** the response SHALL contain the next page of notes in id-sorted order

#### Scenario: Last page has null next_cursor

- **WHEN** the page returned is the final page
- **THEN** `next_cursor` SHALL be `null`

#### Scenario: Items contain metadata only, no content

- **WHEN** a client requests `GET /notes`
- **THEN** items SHALL NOT contain a `content` field

### Requirement: POST /notes creates a new note

`POST /notes` SHALL accept a JSON body with `title` (required, non-empty string) and `content` (optional, defaults to empty string). The server SHALL generate a ULID, write the file with `version: 1`, and return HTTP 201 with the full note record.

#### Scenario: Successful creation returns 201 and full record

- **WHEN** a client posts `{"title":"Meeting","content":"# Hello"}`
- **THEN** the response SHALL have status 201 and body containing `id`, `title`, `content`, `version: 1`, `created_at`, `updated_at`

#### Scenario: Missing title is rejected

- **WHEN** a client posts `{"content":"hi"}`
- **THEN** the response SHALL have status 400 and a JSON body with an `error` field describing the missing field

#### Scenario: Empty title is rejected

- **WHEN** a client posts `{"title":"","content":"hi"}`
- **THEN** the response SHALL have status 400

### Requirement: GET /notes/{id} returns the full note

`GET /notes/{id}` SHALL return a JSON body with `id`, `title`, `content`, `version`, `created_at`, `updated_at`, and an optional `lock` object. When the note is currently locked, `lock` SHALL contain `holder` (string) and `expires_at` (ISO 8601). When unlocked, `lock` SHALL be omitted or `null`. Unknown ids SHALL return HTTP 404.

#### Scenario: Existing note is returned with all fields

- **GIVEN** a note exists at id `01HXY...ABC`
- **WHEN** an authenticated client requests `GET /notes/01HXY...ABC`
- **THEN** the response SHALL be 200 with body containing `id`, `title`, `content`, `version`, `created_at`, `updated_at`

#### Scenario: Locked note includes lock metadata

- **GIVEN** a note is currently locked by actor `alice` until `2026-04-25T12:00:00Z`
- **WHEN** any client requests the note
- **THEN** the response body SHALL include `"lock": {"holder":"alice","expires_at":"2026-04-25T12:00:00Z"}`

#### Scenario: Unknown id returns 404

- **WHEN** a client requests `GET /notes/01HXY...XXX` for an id with no corresponding file
- **THEN** the response SHALL have status 404 and a JSON body `{"error":"not_found"}`

### Requirement: PUT /notes/{id} requires If-Match and uses optimistic concurrency

`PUT /notes/{id}` SHALL accept a JSON body with `title` and/or `content`. The request SHALL include an `If-Match: <version>` header. The server SHALL accept the update only when the supplied version equals the current version. On success the server SHALL return HTTP 200 with the new full note record (including the incremented `version`). On version mismatch the server SHALL return HTTP 409 with the current state.

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

### Requirement: PUT returns 423 when another actor holds the lock

When a note is currently locked by an actor other than the requester, `PUT /notes/{id}` SHALL return HTTP 423 (Locked) with body `{ "error":"locked", "holder": "<name>", "expires_at":"<ts>" }`. The body SHALL NOT include note content. The lock check SHALL run before the version check.

#### Scenario: Different actor locked the note

- **GIVEN** the note is locked by `bob` until a future time
- **WHEN** a request with `X-Actor: alice` sends `PUT /notes/{id}` with a matching `If-Match`
- **THEN** the response SHALL be 423 with the lock holder and expiry

#### Scenario: Lock holder can update freely

- **GIVEN** the note is locked by `alice` until a future time
- **WHEN** a request with `X-Actor: alice` sends `PUT /notes/{id}` with a matching `If-Match`
- **THEN** the response SHALL be 200

### Requirement: DELETE /notes/{id} removes the note

`DELETE /notes/{id}` SHALL remove the note's file from disk, remove its index entry, remove it from the search index, and respond with HTTP 204. Deleting an unknown id SHALL return HTTP 404. The server SHALL respect locks: if another actor holds the lock, the response SHALL be 423.

#### Scenario: Successful delete returns 204

- **GIVEN** an existing note with no active lock
- **WHEN** the owner sends `DELETE /notes/{id}`
- **THEN** the response SHALL be 204 with no body and the file SHALL no longer exist on disk

#### Scenario: Deleting locked note by another actor returns 423

- **GIVEN** the note is locked by `bob`
- **WHEN** a request with `X-Actor: alice` sends `DELETE /notes/{id}`
- **THEN** the response SHALL be 423

#### Scenario: Delete of unknown id returns 404

- **WHEN** a client deletes an id that has no corresponding file
- **THEN** the response SHALL be 404

### Requirement: Successful writes broadcast a `changed` event

Every successful POST, PUT, or DELETE on a note SHALL trigger a `changed` event broadcast over the realtime channel (see `realtime-sync` capability). The broadcast SHALL include the note id, the new version (or `null` for delete), the actor identity, and the action (`created`, `updated`, `deleted`). The broadcast SHALL be best-effort: failure to broadcast SHALL NOT roll back the on-disk write.

#### Scenario: Update broadcasts version 6

- **GIVEN** a note moves from version 5 to 6
- **WHEN** the PUT response is returned
- **THEN** all subscribed WS clients SHALL receive `{"type":"changed","note_id":"...","version":6,"by":"alice","action":"updated"}`

#### Scenario: Delete broadcasts deletion

- **GIVEN** a note is deleted
- **THEN** subscribed clients SHALL receive `{"type":"changed","note_id":"...","version":null,"by":"alice","action":"deleted"}`

### Requirement: Health endpoint reports liveness

The server SHALL expose `GET /healthz`, unauthenticated, returning HTTP 200 with body `{"status":"ok"}` while the process is healthy enough to serve requests.

#### Scenario: Healthy server returns 200

- **WHEN** a client requests `GET /healthz`
- **THEN** the response SHALL be 200 with body `{"status":"ok"}`

### Requirement: All error responses use a consistent JSON shape

Every 4xx and 5xx response from the API SHALL have a JSON body containing at minimum `{"error": "<machine-readable-code>"}`. Additional fields MAY be included to surface state (e.g. `current_version` on 409, `holder`/`expires_at` on 423). Error codes SHALL be stable kebab- or snake-case strings, not human-readable prose.

#### Scenario: 404 has machine-readable error

- **WHEN** the server returns a 404 for an unknown note
- **THEN** the body SHALL include `"error":"not_found"`

#### Scenario: 409 includes current state

- **WHEN** the server returns a 409 for a version conflict
- **THEN** the body SHALL include `error`, `current_version`, `current_content`, and `current_title`

#### Scenario: 423 includes lock holder and expiry

- **WHEN** the server returns a 423
- **THEN** the body SHALL include `error`, `holder`, and `expires_at`

