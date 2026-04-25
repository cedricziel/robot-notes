# robot-notes server API

Single-tenant HTTP + WebSocket API. Every endpoint requires an
`Authorization: Bearer <api-key>` header (the same key the server is
launched with) **except** the public invite-bootstrap endpoint and
`/healthz`. Display identity is supplied via the optional
`X-Actor: <free-text>` header (defaults to `"unknown"`); it is never
authenticated — it's used purely for `by` / `holder` / `viewers`
fields in events.

`Content-Type` is `application/json` for all request and response
bodies unless noted.

For the authoritative behaviour see the specs at
`openspec/changes/add-mvp-foundation/specs/`.

---

## Conventions

### Authentication

```
Authorization: Bearer <api-key>
```

Missing or mismatching → `401 Unauthorized` with the standard error
envelope. The key is whatever the server was started with
(`--api-key` / `ROBOT_NOTES_API_KEY`); rotating the key means
restarting the server.

### Actor identity

```
X-Actor: cedric
```

Free-form; trimmed to a sane length. Echoed back in lock holders,
presence rosters, and `by` fields on `changed` events.

### Optimistic concurrency

`PUT /notes/{id}` requires `If-Match: <version>`. Writes fail closed:
mismatch → `409 Conflict` with the current version and content;
locked-by-someone-else → `423 Locked` with the current lock holder.

### Error envelope

Every non-2xx response uses the same shape:

```json
{
  "error": {
    "code": "version_conflict",
    "message": "Note version has advanced; reload before saving.",
    "details": { "current_version": 7 }
  }
}
```

Common codes: `unauthorized`, `forbidden`, `not_found`,
`version_conflict`, `locked`, `invalid_ttl`, `invite_consumed`,
`invite_expired`, `validation_failed`, `internal_error`.

---

## Endpoints

### `GET /healthz`

Liveness probe. **No auth required.** Returns `200 OK` with body:

```json
{ "status": "ok" }
```

Used by Docker `HEALTHCHECK` and external uptime monitors.

---

### `GET /notes`

List notes, paginated by ULID cursor. Authenticated.

Query parameters:

| Param   | Type | Default | Notes |
| ------- | ---- | ------- | ----- |
| `limit` | int  | 50      | Clamped to `[1, 200]`. |
| `after` | ULID | —       | Returns notes whose id is lexicographically greater than `after` (i.e. newer). |

Response:

```json
{
  "items": [
    {
      "id": "01HM2A...",
      "title": "Inbox",
      "version": 4,
      "updated_at": "2026-04-25T10:14:23Z"
    }
  ],
  "next_cursor": "01HM2A..."
}
```

`next_cursor` is omitted when there is no further page.

---

### `POST /notes`

Create a note. Authenticated.

Request:

```json
{
  "title": "Meeting notes",
  "content": "# Wed\n\n- Bob said …"
}
```

`title` defaults to empty string; `content` defaults to empty string.

Response `201 Created`:

```json
{
  "id": "01HM2A...",
  "version": 1,
  "title": "Meeting notes",
  "content": "# Wed\n\n- Bob said …",
  "created_at": "2026-04-25T10:14:23Z",
  "updated_at": "2026-04-25T10:14:23Z"
}
```

Side-effect: a `changed { id, version: 1, by, action: "created" }`
event is broadcast on the WebSocket.

---

### `GET /notes/{id}`

Read a note. Authenticated. Returns `200 OK`:

```json
{
  "id": "01HM2A...",
  "title": "Meeting notes",
  "content": "...",
  "version": 4,
  "created_at": "...",
  "updated_at": "...",
  "lock": {
    "holder": "alice",
    "expires_at": "2026-04-25T10:15:23Z"
  }
}
```

`lock` is omitted when no editor lock is held. `404 Not Found` if the
id does not exist.

---

### `PUT /notes/{id}`

Update a note. Authenticated. Requires `If-Match: <version>`.

Request:

```json
{ "title": "Meeting notes — Wed", "content": "…" }
```

Successful response `200 OK`:

```json
{ "id": "01HM2A...", "version": 5, "updated_at": "..." }
```

Failure modes:

| Status | Meaning |
| ------ | ------- |
| `400 Bad Request` | `If-Match` missing or malformed. |
| `409 Conflict` | Version stale. Body includes `current_version` and `current_content`. |
| `423 Locked` | Another actor holds the editor lock. Body includes the current lock object. |

Successful writes broadcast `changed { id, version, by, action: "updated" }`.

---

### `DELETE /notes/{id}`

Delete a note. Authenticated. Returns `204 No Content`. Broadcasts
`changed { id, version: <last>, by, action: "deleted" }`. Deleting a
note while it is locked by someone else returns `423 Locked`.

---

### `POST /notes/{id}/lock`

Acquire the editor lock for a note. Authenticated.

Request body: empty.

Response `200 OK`:

```json
{ "holder": "cedric", "expires_at": "2026-04-25T10:15:23Z" }
```

If another actor holds the lock and it has not expired → `423 Locked`
with the current lock object. The server never auto-steals — clients
must wait for the TTL or for the holder to release.

Lock TTL is ~60s; clients SHOULD heartbeat at half-TTL.

### `PUT /notes/{id}/lock`

Heartbeat the lock. Authenticated. Same actor only. Returns the
refreshed `{ holder, expires_at }`. `423 Locked` if the caller does
not own the lock.

### `DELETE /notes/{id}/lock`

Release the lock. Authenticated. Same actor only. Returns `204 No Content`.

Lock state changes broadcast `lock { id, state: "acquired"|"released", holder }`
on the WebSocket.

---

### `GET /search?q=…`

Full-text search backed by SQLite FTS5. Authenticated.

Query parameters:

| Param   | Type   | Default | Notes |
| ------- | ------ | ------- | ----- |
| `q`     | string | —       | Required. Empty/whitespace returns `400 validation_failed`. |
| `limit` | int    | 50      | Clamped to `[1, 200]`. |

Response:

```json
{
  "items": [
    {
      "id": "01HM2A...",
      "title": "Meeting notes",
      "snippet": "…the <mark>budget</mark> question is…",
      "rank": -1.41
    }
  ],
  "limit": 50
}
```

`<mark>…</mark>` markup comes from FTS5's `snippet()` function and is
intended for the client to render with emphasis. `rank` follows FTS5
convention: lower (more negative) = better match.

---

### `POST /invites`

Mint a single-use, time-bound invite that lets an agent bootstrap
itself with a single fetch. Authenticated.

Request body (all fields optional):

```json
{ "label": "research-bot", "ttl_seconds": 3600 }
```

`ttl_seconds` defaults to 86400 (24h), maximum 2592000 (30d). Out of
range → `400 invalid_ttl`.

Response `201 Created`:

```json
{
  "token": "…opaque…",
  "url": "https://notes.example.com/invites/…opaque…/onboarding.txt",
  "expires_at": "2026-04-26T10:14:23Z",
  "single_use": true,
  "label": "research-bot"
}
```

The URL itself is bearer-equivalent — treat it like a credential.

### `GET /invites`

List currently outstanding invites (pending + recently consumed).
Authenticated. Returns:

```json
{
  "items": [
    {
      "token": "…",
      "label": "…",
      "created_at": "…",
      "expires_at": "…",
      "burned_at": null
    }
  ]
}
```

### `DELETE /invites/{token}`

Revoke an invite. Authenticated. Returns `204 No Content`. Idempotent
— deleting an already-consumed or already-revoked invite still
returns `204`.

### `GET /invites/{token}/onboarding.txt`

Public, **single-use** bootstrap endpoint. **No `Authorization`
header** — the URL itself is the credential. Returns
`text/plain; charset=utf-8` with a parseable bundle:

```
ROBOT_NOTES_BASE_URL=https://notes.example.com
ROBOT_NOTES_API_KEY=rn_your_secret
ROBOT_NOTES_ACTOR=research-bot
```

The first successful fetch sets `burned_at`; subsequent fetches
return `410 Gone` with code `invite_consumed`. Expired invites
return `410 Gone` with code `invite_expired`.

---

## WebSocket: `/ws`

Single endpoint. The connection upgrades from HTTP, and the client
authenticates and subscribes via JSON envelopes after the upgrade.

### Hello / auth

Client sends:

```json
{
  "type": "auth",
  "api_key": "rn_your_secret",
  "actor": "cedric"
}
```

Server replies:

```json
{ "type": "auth_ok", "session_id": "…" }
```

or closes the connection with code `4401` on a bad key.

### Subscribe / unsubscribe

```json
{ "type": "subscribe",   "note_id": "01HM2A..." }
{ "type": "unsubscribe", "note_id": "01HM2A..." }
```

Or wildcard subscription:

```json
{ "type": "subscribe", "note_id": "*" }
```

### Server-pushed events

```json
{ "type": "presence", "note_id": "01HM2A...", "viewers": ["cedric", "alice"] }

{ "type": "lock", "note_id": "01HM2A...", "state": "acquired",
  "holder": "alice", "expires_at": "..." }

{ "type": "changed", "note_id": "01HM2A...", "version": 5,
  "by": "alice", "action": "updated" }
```

`action` is one of `created`, `updated`, `deleted`. The server does
**not** stream keystrokes — only version-bump notifications.
Real-time editing convergence is intentionally out of scope for v1.

### Heartbeats

Client sends `{ "type": "ping" }` periodically; server replies
`{ "type": "pong" }`. The server closes idle connections after the
configured grace period.

---

## Versioning compatibility

The API is forward-compatible with future CRDT-based editing:

- The `version` field on a note will continue to be a monotonically
  increasing counter.
- `changed` events will continue to fire at version bumps.
- New event types and message kinds will be added without renaming
  existing ones; clients SHOULD ignore unknown `type` values.
