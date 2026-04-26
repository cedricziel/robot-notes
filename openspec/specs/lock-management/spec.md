# lock-management Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Server exposes lock endpoints per note

The server SHALL expose three endpoints for managing the editor lock on a note:

- `POST /notes/{id}/lock` — acquire
- `PUT /notes/{id}/lock` — heartbeat (extend TTL)
- `DELETE /notes/{id}/lock` — release

All three SHALL require authentication and SHALL accept the actor identity from the `X-Actor` header.

#### Scenario: All three lock endpoints are routable

- **WHEN** an authenticated client issues each of POST, PUT, and DELETE on `/notes/{id}/lock`
- **THEN** each request SHALL be matched by a route handler

### Requirement: Locks are exclusive, in-memory, and per-note

The server SHALL maintain at most one active lock per note id. Lock state SHALL live entirely in process memory and SHALL be discarded on server restart. The server SHALL track for each lock: the `holder` (actor string) and the `expires_at` (UTC timestamp).

#### Scenario: Restart discards all locks

- **GIVEN** notes A and B are locked by `alice` and `bob` respectively
- **WHEN** the server restarts
- **THEN** both notes SHALL be unlocked

#### Scenario: At most one lock per note

- **GIVEN** the lock state for note X is empty
- **WHEN** two acquire requests with different actors arrive concurrently
- **THEN** exactly one SHALL succeed and the other SHALL receive 423

### Requirement: Acquire creates a lock when no active lock exists

`POST /notes/{id}/lock` SHALL succeed when there is no active lock for the note OR when the existing lock has expired. On success the server SHALL set the holder to the requesting actor and the TTL to 60 seconds, return HTTP 200 with `{"holder":"<actor>","expires_at":"<ts>"}`, and broadcast a `lock` event.

#### Scenario: Acquire on unlocked note

- **GIVEN** note X has no active lock
- **WHEN** a request with `X-Actor: alice` sends `POST /notes/X/lock`
- **THEN** the response SHALL be 200 with `holder: "alice"` and `expires_at` ~60 seconds in the future

#### Scenario: Acquire on expired lock

- **GIVEN** the lock for note X is held by `bob` with `expires_at` in the past
- **WHEN** a request with `X-Actor: alice` sends `POST /notes/X/lock`
- **THEN** the response SHALL be 200 with `holder: "alice"`

### Requirement: Acquire returns 423 when another active lock holder exists

When `POST /notes/{id}/lock` is called and another actor holds an unexpired lock on the same note, the server SHALL respond with HTTP 423 and a body containing the current `holder` and `expires_at`. The same actor reacquiring its own lock SHALL behave like a heartbeat (200, TTL extended).

#### Scenario: Different actor blocked by active lock

- **GIVEN** note X is locked by `bob` until a future time
- **WHEN** a request with `X-Actor: alice` sends `POST /notes/X/lock`
- **THEN** the response SHALL be 423 with `holder: "bob"` and the existing `expires_at`

#### Scenario: Same actor reacquire is idempotent

- **GIVEN** note X is locked by `alice` with `expires_at` in 30 seconds
- **WHEN** the same actor sends `POST /notes/X/lock`
- **THEN** the response SHALL be 200 and `expires_at` SHALL be approximately 60 seconds in the future

### Requirement: Heartbeat extends the holder's TTL

`PUT /notes/{id}/lock` SHALL extend the holder's `expires_at` to 60 seconds in the future when the requesting actor matches the current holder. The server SHALL respond with HTTP 200 and the new lock state and SHALL broadcast a `lock` event with the new expiry. Heartbeat from a non-holder SHALL return HTTP 423 with the current holder. Heartbeat for a non-existent or expired lock SHALL return HTTP 404.

#### Scenario: Holder heartbeat extends expiry

- **GIVEN** note X is locked by `alice` with `expires_at` in 10 seconds
- **WHEN** a request with `X-Actor: alice` sends `PUT /notes/X/lock`
- **THEN** the response SHALL be 200 and the new `expires_at` SHALL be approximately 60 seconds in the future

#### Scenario: Non-holder heartbeat is rejected

- **GIVEN** note X is locked by `alice`
- **WHEN** a request with `X-Actor: bob` sends `PUT /notes/X/lock`
- **THEN** the response SHALL be 423

#### Scenario: Heartbeat on expired lock returns 404

- **GIVEN** note X has no active lock (the previous lock has expired)
- **WHEN** any actor sends `PUT /notes/X/lock`
- **THEN** the response SHALL be 404

### Requirement: Release removes the lock when called by the holder

`DELETE /notes/{id}/lock` SHALL remove the active lock when the requesting actor is the current holder, return HTTP 204, and broadcast a `lock` event indicating the unlocked state. Release by a non-holder SHALL return HTTP 423. Release of a non-existent or already-expired lock SHALL return HTTP 204 (idempotent).

#### Scenario: Holder releases successfully

- **GIVEN** note X is locked by `alice`
- **WHEN** a request with `X-Actor: alice` sends `DELETE /notes/X/lock`
- **THEN** the response SHALL be 204, the lock SHALL be cleared, and a `lock` event SHALL be broadcast

#### Scenario: Non-holder cannot release

- **GIVEN** note X is locked by `alice`
- **WHEN** a request with `X-Actor: bob` sends `DELETE /notes/X/lock`
- **THEN** the response SHALL be 423

#### Scenario: Release of expired lock is idempotent

- **GIVEN** note X has no active lock
- **WHEN** any actor sends `DELETE /notes/X/lock`
- **THEN** the response SHALL be 204

### Requirement: Locks expire automatically by TTL

The server SHALL treat any lock whose `expires_at` is in the past as if it does not exist. The server SHALL NOT require a background timer to release expired locks; it SHALL evaluate expiry lazily on every read or check of the lock state. The server SHALL emit a `lock` event indicating the unlocked state on the first observation that an active lock has expired.

#### Scenario: Expired lock does not block new acquire

- **GIVEN** note X has a lock by `bob` with `expires_at` 10 seconds in the past
- **WHEN** a request with `X-Actor: alice` sends `POST /notes/X/lock`
- **THEN** the response SHALL be 200 and `holder` SHALL be `alice`

#### Scenario: Expired lock is reported as no lock on GET

- **GIVEN** note X has an expired lock
- **WHEN** a client requests `GET /notes/X`
- **THEN** the response body SHALL omit `lock` (or set it to `null`)

### Requirement: Lock state is included in note reads and broadcast on changes

`GET /notes/{id}` SHALL include the active lock state when present (per `notes-api`). Every lock state transition (acquire, heartbeat, release, expiry) SHALL produce a `lock` WebSocket event for subscribers of that note id (per `realtime-sync`).

#### Scenario: Acquire produces a lock event

- **WHEN** a successful acquire happens for note X
- **THEN** subscribers of X SHALL receive `{"type":"lock","note_id":"X","holder":"alice","expires_at":"..."}`

#### Scenario: Release produces a lock event with no holder

- **WHEN** a release happens for note X
- **THEN** subscribers SHALL receive `{"type":"lock","note_id":"X","holder":null,"expires_at":null}`

### Requirement: Lock TTL is configurable but defaults to 60 seconds

The server SHALL default lock TTL to 60 seconds. Operators MAY override via a `--lock-ttl-seconds <n>` CLI argument or `ROBOT_NOTES_LOCK_TTL_SECONDS` env var. The configured TTL SHALL apply to every acquire and heartbeat. The TTL SHALL be at least 5 seconds.

#### Scenario: Default TTL is 60 seconds

- **GIVEN** the server is started with no TTL flag or env var
- **WHEN** an acquire succeeds at time T
- **THEN** the returned `expires_at` SHALL be approximately T + 60 seconds

#### Scenario: Override via CLI

- **GIVEN** the server is started with `--lock-ttl-seconds 30`
- **WHEN** an acquire succeeds at time T
- **THEN** the returned `expires_at` SHALL be approximately T + 30 seconds

#### Scenario: Below-minimum TTL is rejected at startup

- **WHEN** the server is invoked with `--lock-ttl-seconds 2`
- **THEN** the server SHALL exit with a non-zero status and an error message

