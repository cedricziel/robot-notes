# realtime-sync Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Server exposes a single WebSocket endpoint at /ws

The server SHALL expose exactly one WebSocket endpoint at `/ws`. All real-time interactions for the API SHALL flow through this endpoint. Multiple concurrent connections SHALL be permitted.

#### Scenario: Client can connect to /ws

- **WHEN** a client opens a WebSocket connection to `/ws`
- **THEN** the connection SHALL be accepted (subject to subsequent auth)

### Requirement: Connection lifecycle starts with an auth message

Within 2 seconds of connection the client SHALL send `{"type":"auth","key":"<bearer-key>","actor":"<display-name>"}`. The server SHALL validate the key against the configured bearer key. On success it SHALL respond with `{"type":"auth_ok"}` and bind the connection's actor identity. On failure it SHALL close with code 4001 (per `auth` capability).

#### Scenario: Successful auth bind

- **WHEN** a client connects and sends `{"type":"auth","key":"<configured>","actor":"alice"}`
- **THEN** the server SHALL respond with `{"type":"auth_ok"}` and SHALL identify subsequent activity from this connection as `"alice"`

#### Scenario: Missing actor defaults to "unknown"

- **WHEN** a client connects and sends `{"type":"auth","key":"<configured>"}` (no `actor`)
- **THEN** the connection's actor identity SHALL be `"unknown"`

### Requirement: Clients subscribe per note or to all notes

After successful authentication, clients SHALL send `{"type":"subscribe","note_id":"<id>"}` to receive events for that note, or `{"type":"subscribe","note_id":"*"}` to receive events for all notes. Clients MAY send any number of subscribe messages; subscriptions SHALL accumulate. Clients SHALL send `{"type":"unsubscribe","note_id":"<id>"}` to stop receiving events for a particular note.

#### Scenario: Per-note subscription

- **GIVEN** an authenticated connection
- **WHEN** the client sends `{"type":"subscribe","note_id":"X"}`
- **THEN** future events for note X (and only X) SHALL be delivered to this connection

#### Scenario: Wildcard subscription

- **GIVEN** an authenticated connection
- **WHEN** the client sends `{"type":"subscribe","note_id":"*"}`
- **THEN** events for all notes SHALL be delivered to this connection

#### Scenario: Unsubscribe stops delivery

- **GIVEN** a connection subscribed to note X
- **WHEN** the client sends `{"type":"unsubscribe","note_id":"X"}`
- **THEN** subsequent events for X SHALL NOT be delivered

#### Scenario: Subscription before auth is rejected

- **GIVEN** a connection that has not yet authenticated
- **WHEN** the client sends a subscribe message
- **THEN** the server SHALL ignore the message and SHALL NOT deliver any events

### Requirement: Server emits `presence` events when subscribers change

The server SHALL track which actors are subscribed to each note. When the set of subscribers for a note changes (a connection subscribes, unsubscribes, or disconnects), the server SHALL emit `{"type":"presence","note_id":"<id>","viewers":["actor1","actor2",...]}` to all current subscribers of that note. The viewers list SHALL contain unique actor names; if a single actor has multiple connections subscribed, the actor SHALL appear once.

#### Scenario: Subscription emits presence to subscribers

- **GIVEN** alice is subscribed to note X
- **WHEN** bob subscribes to note X
- **THEN** both alice and bob SHALL receive `{"type":"presence","note_id":"X","viewers":["alice","bob"]}`

#### Scenario: Disconnect emits presence

- **GIVEN** alice and bob are subscribed to note X
- **WHEN** bob's connection closes
- **THEN** alice SHALL receive a presence event with `viewers: ["alice"]`

#### Scenario: Wildcard subscribers receive per-note presence

- **GIVEN** carol is subscribed with `note_id: "*"` and alice is subscribed to X
- **WHEN** bob subscribes to note X
- **THEN** carol SHALL receive `{"type":"presence","note_id":"X","viewers":["alice","bob"]}`

#### Scenario: Multiple connections from one actor count once

- **GIVEN** alice has two open WS connections both subscribed to note X
- **WHEN** the presence list for note X is computed
- **THEN** `viewers` SHALL contain `"alice"` exactly once

### Requirement: Server emits `lock` events on lock state transitions

On every lock acquire, heartbeat, release, or first-observed expiry (per `lock-management`), the server SHALL emit a `lock` event to all current subscribers of that note (including wildcard subscribers). The event SHALL have shape `{"type":"lock","note_id":"<id>","holder":"<actor>|null","expires_at":"<iso>|null"}`.

#### Scenario: Acquire emits lock event

- **GIVEN** subscribers exist for note X
- **WHEN** an acquire succeeds with `holder: "alice"` and `expires_at: "T"`
- **THEN** all subscribers SHALL receive `{"type":"lock","note_id":"X","holder":"alice","expires_at":"T"}`

#### Scenario: Release emits null holder

- **WHEN** a successful release happens for note X
- **THEN** subscribers SHALL receive `{"type":"lock","note_id":"X","holder":null,"expires_at":null}`

### Requirement: Server emits `changed` events on note writes

On every successful create, update, or delete of a note (per `notes-api`), the server SHALL emit a `changed` event to all current subscribers of that note (including wildcard subscribers). The event SHALL have shape `{"type":"changed","note_id":"<id>","version":<int>|null,"by":"<actor>","action":"created|updated|deleted"}`. The event SHALL NOT include note content; clients SHALL fetch via HTTP to retrieve content.

#### Scenario: Update emits changed event with new version

- **GIVEN** subscribers exist for note X
- **WHEN** a successful PUT brings note X to version 6 by actor `alice`
- **THEN** subscribers SHALL receive `{"type":"changed","note_id":"X","version":6,"by":"alice","action":"updated"}`

#### Scenario: Delete emits changed event with null version

- **WHEN** note X is successfully deleted by `alice`
- **THEN** subscribers SHALL receive `{"type":"changed","note_id":"X","version":null,"by":"alice","action":"deleted"}`

#### Scenario: Created note emits version 1

- **WHEN** a new note is successfully created by `alice`
- **THEN** subscribers (including wildcard) SHALL receive a `changed` event with `version: 1` and `action: "created"`

### Requirement: Events are JSON over text frames; binary frames are rejected

All messages between client and server SHALL be UTF-8 JSON sent as text frames. The server SHALL close any connection that sends a binary frame with code 1003 (Unsupported Data).

#### Scenario: Binary frame closes connection

- **GIVEN** an authenticated connection
- **WHEN** the client sends a binary frame
- **THEN** the server SHALL close the connection with code 1003

### Requirement: Server tolerates slow consumers without blocking writers

The server's broadcast SHALL NOT block on a slow or stalled WebSocket consumer. If a connection's send buffer is unable to accept new events, the server SHALL drop subsequent events for that connection and SHALL close it with code 1011 after a short grace period.

#### Scenario: Slow consumer is dropped, others are unaffected

- **GIVEN** subscribers `alice` (fast) and `bob` (stalled) on note X
- **WHEN** the server broadcasts a `changed` event
- **THEN** alice SHALL receive the event promptly
- **AND** bob's connection SHALL be closed if its buffer cannot accept the message within the grace period
- **AND** the broadcast call to alice SHALL NOT be delayed by bob

### Requirement: Server emits a `pong` in response to client `ping`

To support keepalive at the application layer, the server SHALL respond to `{"type":"ping","id":"<opaque>"}` with `{"type":"pong","id":"<same-opaque>"}`. The server MAY additionally use WebSocket protocol-level ping/pong frames; their behavior is implementation-defined.

#### Scenario: Application-level ping is echoed

- **GIVEN** an authenticated connection
- **WHEN** the client sends `{"type":"ping","id":"abc"}`
- **THEN** the server SHALL reply with `{"type":"pong","id":"abc"}`

### Requirement: Unknown message types are ignored with an error reply

When the server receives a JSON message with a `type` it does not recognize, it SHALL reply with `{"type":"error","error":"unknown_type","received":"<original-type>"}` and SHALL NOT close the connection.

#### Scenario: Unknown type elicits error message

- **WHEN** an authenticated client sends `{"type":"explode"}`
- **THEN** the server SHALL reply `{"type":"error","error":"unknown_type","received":"explode"}` and SHALL keep the connection open

