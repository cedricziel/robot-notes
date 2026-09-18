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

When the server is configured for OIDC login (see below), a REST or
WebSocket request may also carry an OAuth access token issued by this
server's own authorization server, scoped to `<base>` (as opposed to
`<base>/mcp` — the two are different audiences and a token minted for
one is rejected on the other). Such a token unlocks `notes:read` /
`notes:write` per its granted scope; a request that needs a scope the
token lacks gets `403` with `insufficient_scope` rather than `401`.

### Actor identity

```
X-Actor: cedric
```

Free-form; trimmed to a sane length. Echoed back in lock holders,
presence rosters, and `by` fields on `changed` events. For a request
authenticated with an OIDC-derived OAuth token, `X-Actor` is ignored —
the actor comes from the token's grant instead (see OIDC login,
below), since that identity is cryptographically verified rather than
client-asserted.

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

List notes, paginated by cursor. Authenticated.

Query parameters:

| Param   | Type   | Default | Notes                                                                                             |
| ------- | ------ | ------- | ------------------------------------------------------------------------------------------------- |
| `limit` | int    | 50      | Clamped to `[1, 200]`.                                                                            |
| `after` | string | —       | Opaque cursor from a previous response's `next_cursor`.                                           |
| `sort`  | string | `id`    | `id` (ascending, backward-compatible) or `updated_desc` (most-recently-updated first).            |
| `path`  | string | —       | Restrict to notes whose `path` equals or is nested under this folder, e.g. `path=Projects/Alpha`. |
| `tag`   | string | —       | Restrict to notes carrying this tag (case-insensitive).                                           |
| `title` | string | —       | Restrict to the note whose title exactly matches (Unicode-NFC and case-insensitive — the same normalization the path-conflict check uses). |

`path`, `tag` and `title` compose with each other and with either `sort`.

Response:

```json
{
  "items": [
    {
      "id": "01HM2A...",
      "title": "Inbox",
      "path": "",
      "version": 4,
      "created_at": "2026-04-20T09:00:00Z",
      "updated_at": "2026-04-25T10:14:23Z",
      "excerpt": "Weekly review notes and open questions…",
      "tags": ["planning", "urgent"]
    }
  ],
  "next_cursor": "01HM2A..."
}
```

`excerpt` is a bounded (~140 character), markdown-stripped preview of the
note's body — never the full content. `tags` is the note's computed tag
set (same set the `tag` filter matches against), sorted ascending,
case-insensitively. `next_cursor` is `null` when there is no further page.

---

### `GET /notes/tree`

Return the vault's folder structure without paginating individual
notes. Authenticated.

```json
{
  "folders": [
    { "path": "", "note_count": 2, "file_count": 0 },
    { "path": "Projects/Alpha", "note_count": 1, "file_count": 0 },
    { "path": "Attachments", "note_count": 0, "file_count": 3 }
  ]
}
```

Only folders that **directly** contain at least one note or file, or
were explicitly created empty (see `POST /notes/tree` below), are
listed (an intermediate folder with no notes/files of its own and
never explicitly created, only a populated descendant, is omitted);
`note_count`/`file_count` each count direct children only. A client
that wants intermediate tree nodes or aggregate counts derives them
from these leaf paths.

---

### `POST /notes/tree`

Create an empty folder (and any missing intermediate folders along
`path`), persisted via a marker file (see "Empty-folder markers" in
`STORAGE.md`) so it survives a restart even with no notes in it.
Authenticated.

Request:

```json
{ "path": "Ideas" }
```

`path` is required, non-empty, `/`-separated, with no leading or
trailing slash.

Response `201 Created` when the folder did not already exist:

```json
{ "path": "Ideas", "note_count": 0 }
```

Idempotent: a `path` that already resolves to an existing folder
(whether it holds notes, a marker, or both — including a
case/NFC-only spelling difference) responds `200 OK` with that
folder's current state instead of an error:

```json
{ "path": "Projects/Alpha", "note_count": 2 }
```

An empty `path` is rejected with `400 Bad Request` — the vault root
always exists and never needs creating.

---

### `POST /notes/files`

Upload a non-note file directly into the vault (a real HTTP client
with the bytes already in hand — the Flutter app's FAB, for instance).
`multipart/form-data`: a `path` field (target folder, same convention
as a note's `path`) and a `file` field (the upload, carrying its own
filename). Authenticated.

Response `201 Created`:

```json
{
  "path": "Ideas",
  "filename": "diagram.png",
  "size": 4821,
  "content_type": "image/png"
}
```

`409 Conflict` (`{"error": "path_conflict"}`) on a filename collision
with an existing note, file, or empty-folder marker — no overwrite, no
auto-rename. `413 Payload Too Large`
(`{"error": "payload_too_large"}`) over the configured max upload size
(see `notes-storage`'s `maxUploadSizeBytes`), rejected without writing
a partial file. `400 Bad Request` for an invalid `path` segment or a
missing `path`/`file` field.

---

### `GET /notes/files/{path}`

Retrieve a previously uploaded file's raw bytes, `Content-Type`
derived from the extension (falling back to `application/octet-stream`
for an unrecognized one). Authenticated. `404 Not Found` when nothing
exists at `path`.

---

### `GET /notes/files?path=`

List a folder's files directly (not recursing into subfolders); an
empty or omitted `path` lists the vault root's. Authenticated. Flat,
unpaginated — see `add-file-upload`'s design.md for why (this isn't
the note-listing use case pagination exists for).

```json
{
  "items": [
    {
      "path": "Ideas",
      "filename": "diagram.png",
      "size": 4821,
      "content_type": "image/png",
      "updated_at": "2026-04-25T10:00:00.000Z"
    }
  ]
}
```

---

### `PUT /notes/file-uploads/{token}`

Completes a two-phase upload reserved by the MCP `request_upload` tool
(see "Tool catalog" below) — an agent's control-plane call never
carries the file's bytes; this is the only step that does. Accepts the
raw request body as the file's bytes (**not** multipart).

**Not gated by the normal bearer key** — `token` itself (16 bytes of
secure randomness, single-use, short TTL, scoped to one path+filename
pair) is the credential, the same trust model a cloud-storage
presigned URL uses. This lets whatever actually holds the bytes (a
sandboxed `curl`, the agent's host process) perform the transfer
without needing the broader API key.

Response `200 OK`:

```json
{
  "token": "...",
  "size": 4821,
  "content_type": "image/png",
  "expires_at": "2026-04-25T10:15:00.000Z"
}
```

`404 Not Found` for a missing, expired, or already-completed token.
`413 Payload Too Large` over the configured max upload size, aborting
and discarding any partial data. Completing the `PUT` does **not**
place the file in the vault — the caller still has to call
`finalize_upload` (MCP) afterward.

---

### `GET /tags`

List every distinct tag across all notes, with counts, sorted by
descending count. Authenticated.

```json
{
  "items": [
    { "tag": "urgent", "count": 3 },
    { "tag": "later", "count": 1 }
  ]
}
```

See "Tags" in `STORAGE.md` for how a note's tags are computed.

---

### `POST /notes`

Create a note. Authenticated.

Request:

```json
{
  "title": "Meeting notes",
  "content": "# Wed\n\n- Bob said …",
  "path": "Projects/Alpha"
}
```

`title` defaults to empty string; `content` defaults to empty string;
`path` defaults to the empty string (vault root).

Response `201 Created`:

```json
{
  "id": "01HM2A...",
  "version": 1,
  "title": "Meeting notes",
  "path": "Projects/Alpha",
  "content": "# Wed\n\n- Bob said …",
  "created_at": "2026-04-25T10:14:23Z",
  "updated_at": "2026-04-25T10:14:23Z",
  "tags": []
}
```

If the resolved `<path>/<title>` collides with another note's file,
the response is `409 Conflict` with `{"error":"path_conflict"}` instead.

Side-effect: a `changed { id, version: 1, by, action: "created" }`
event is broadcast on the WebSocket.

---

### `GET /notes/{id}`

Read a note. Authenticated. Returns `200 OK`:

```json
{
  "id": "01HM2A...",
  "title": "Meeting notes",
  "path": "Projects/Alpha",
  "content": "...",
  "version": 4,
  "created_at": "...",
  "updated_at": "...",
  "tags": ["urgent"],
  "lock": {
    "holder": "alice",
    "expires_at": "2026-04-25T10:15:23Z"
  }
}
```

`lock` is omitted when no editor lock is held. `404 Not Found` if the
id does not exist.

---

### `GET /notes/{id}/backlinks`

List notes whose content contains a `[[...]]` link resolving to this
note, most-recently-updated first. Authenticated. `404 Not Found` if
the id does not exist.

```json
{
  "items": [
    {
      "id": "01HM2B...",
      "title": "Meeting Notes",
      "snippet": "See [[Project Alpha]] for details"
    }
  ]
}
```

### `GET /notes/{id}/links`

List this note's own outgoing `[[...]]` links. Authenticated. `404 Not
Found` if the id does not exist. `id` is present only when the link
resolved to an existing note; an unresolved ("phantom") link has
`resolved: false` and no `id`.

```json
{
  "items": [
    { "title": "Project Alpha", "resolved": true, "id": "01HM2A..." },
    { "title": "Not Yet Written", "resolved": false }
  ]
}
```

---

### `PUT /notes/{id}`

Update a note. Authenticated. Requires `If-Match: <version>`.

Request (any of `title`, `content`, `path`; `content` defaults to
empty string when omitted, so a title/path-only rename should still
send the note's current `content` if it must be preserved):

```json
{ "title": "Meeting notes — Wed", "content": "…", "path": "Projects/Alpha" }
```

Successful response `200 OK` (same shape as `GET /notes/{id}` minus
`lock`). A `title` change renames the underlying file; a `path` change
moves it — both under the same `If-Match`/lock rules as any other
write. If the note's title changes, every other note with a parsed
`[[...]]` link to the old title is rewritten to the new title as a
normal follow-up write (see "Links" in `STORAGE.md`).

Failure modes:

| Status            | Meaning                                                                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `400 Bad Request` | `If-Match` missing or malformed.                                                                                                          |
| `409 Conflict`    | Version stale (`current_version`/`current_content`), or the resolved `path` collides with a different note (`{"error":"path_conflict"}`). |
| `423 Locked`      | Another actor holds the editor lock. Body includes the current lock object.                                                               |

Successful writes broadcast `changed { id, version, by, action }`,
where `action` is `"moved"` when `path` changed (even alongside a
title/content change) and `"updated"` otherwise.

---

### `POST /notes/{id}/append`

Append text to the end of a note as a safe server-side
read-modify-write — no `If-Match` needed. The server reads the
current content, appends the given text on a new line (unless the
note is empty, or its content already ends with one), and retries
internally if another writer's version race is lost, up to the same
retry budget as the MCP `append_to_note` tool. REST twin of that
tool: both call the same server-side helper, so semantics (newline
handling, retry count, lock/scope handling, broadcast) are identical.

Request:

```json
{ "content": "- another line" }
```

Successful response `200 OK` (same shape as `GET /notes/{id}` minus
`lock`), reflecting the appended content and bumped `version`.

Failure modes:

| Status                | Meaning                                                                 |
| --------------------- | ------------------------------------------------------------------------ |
| `400 Bad Request`     | Body isn't JSON, or `content` is missing/empty (`validation_failed`).  |
| `404 Not Found`       | No note with this id.                                                  |
| `423 Locked`          | Another actor holds the editor lock. Body includes the current lock object. |

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

| Param   | Type   | Default | Notes                                                                         |
| ------- | ------ | ------- | ----------------------------------------------------------------------------- |
| `q`     | string | —       | Required. Empty/whitespace returns `400 validation_failed`.                   |
| `limit` | int    | 20      | Clamped to `[1, 100]`.                                                        |
| `path`  | string | —       | Restrict matches to notes whose `path` equals or is nested under this folder. |
| `tag`   | string | —       | Restrict matches to notes carrying this tag.                                  |

Response:

```json
{
  "items": [
    {
      "id": "01HM2A...",
      "title": "Meeting notes",
      "path": "Projects/Alpha",
      "snippet": "…the <mark>budget</mark> question is…",
      "rank": -1.41
    }
  ],
  "limit": 20
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

`action` is one of `created`, `updated`, `moved`, `deleted`. `moved`
fires when a `PUT` changes a note's `path` (even alongside a
title/content change); a rename-propagation rewrite to a _different_
note (see "Links" in `STORAGE.md`) broadcasts as an ordinary `updated`
for that note, since it's just a normal write from the server's point
of view. The server does **not** stream keystrokes — only version-bump
notifications. Real-time editing convergence is intentionally out of
scope for v1.

### Heartbeats

Client sends `{ "type": "ping" }` periodically; server replies
`{ "type": "pong" }`. The server closes idle connections after the
configured grace period.

---

## Connecting an MCP client

`POST <base>/mcp` exposes the note workspace as an MCP (Streamable
HTTP) endpoint: one JSON-RPC 2.0 message per request, one JSON response
per request, no sessions, no server-sent events. `GET`/`DELETE /mcp`
return `405 Method Not Allowed`.

### Authentication

Either credential is accepted as `Authorization: Bearer <credential>`:

- The configured static API key — same as every other endpoint. The
  actor comes from `X-Actor` (defaulting to `unknown`), same as the
  REST API.
- An OAuth access token issued by this server's own authorization
  server (see below). The actor is whichever name was captured at
  consent; `X-Actor` is ignored so a token cannot be used to spoof a
  different actor by header.

A missing or rejected credential returns `401` with
`{ "error": "unauthorized" }` and a `WWW-Authenticate` header pointing
at `<base>/.well-known/oauth-protected-resource/mcp`; a rejected (as
opposed to absent) credential additionally carries
`error="invalid_token"`.

### OAuth discovery and registration

A client that doesn't already hold the static key discovers everything
it needs from two unauthenticated metadata documents and registers
itself without any operator involvement:

| Endpoint                                          | Purpose                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GET /.well-known/oauth-protected-resource[/mcp]` | RFC 9728 resource metadata: the resource URL, the authorization server, supported scopes.                                                                                                                                                                                                                                |
| `GET /.well-known/oauth-authorization-server`     | RFC 8414 AS metadata: authorization/token/registration/revocation endpoints, supported PKCE methods and scopes.                                                                                                                                                                                                          |
| `POST /oauth/register`                            | RFC 7591 Dynamic Client Registration. No auth required; returns a `client_id` (and a `client_secret` for confidential clients).                                                                                                                                                                                          |
| `GET`/`POST /oauth/authorize`                     | Renders, then processes, a browser consent page. The page asks for the workspace API key (proof of ownership) and a display name — the actor the resulting grant writes under. When OIDC login is configured, the page instead offers a "Sign in with your identity provider" link as an alternative to pasting the key. |
| `POST /oauth/token`                               | Authorization-code (with PKCE) and refresh-token exchange.                                                                                                                                                                                                                                                               |
| `POST /oauth/revoke`                              | Revokes an access or refresh token; revoking a refresh token revokes the whole grant.                                                                                                                                                                                                                                    |

Access tokens are valid for 1 hour; refresh tokens for 30 days and
rotate on each use. Tokens are bound to the resource they were
requested for (`<base>/mcp` for MCP clients, `<base>` for the app's
own REST/WebSocket sign-in) and to a scope set drawn from `notes:read`
and `notes:write`; a token missing `notes:write` gets an
`insufficient_scope` tool error from any write tool, or a `403` on a
REST write.

### OIDC login

Configuring all three of `--oidc-issuer`, `--oidc-client-id`, and
`--oidc-client-secret` (env: `ROBOT_NOTES_OIDC_ISSUER`,
`ROBOT_NOTES_OIDC_CLIENT_ID`, `ROBOT_NOTES_OIDC_CLIENT_SECRET`) turns
on a second, human-facing way to satisfy consent, alongside — never
instead of — the static key. Consent then branches:

- `GET/POST /oauth/oidc/login` starts an OIDC authorization-code +
  PKCE flow against the configured issuer, forwarding along the
  original `/oauth/authorize` request's client/redirect/scope/state so
  the callback can resume it.
- `GET /oauth/oidc/callback` exchanges the provider's code, verifies
  the returned ID token (signature via the issuer's published JWKS,
  plus issuer/audience/expiry/nonce checks), derives the actor from
  the token's `name`, falling back to `email`, then `sub`, and mints
  the same kind of authorization code that the static-key path would
  have.

Any successful OIDC login grants full access — there is no per-user
authorization tier. This server supports exactly one OIDC provider per
deployment. Leaving the three settings unset disables OIDC entirely;
the consent page falls back to the paste-the-key form as before.

### Tool catalog

`tools/list` always returns the same twelve tools, regardless of scope
(scope is enforced per call, not per listing):

| Tool              | What it does                                                                                                                  |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `list_notes`      | Paginated note metadata (id, title, path, version, timestamps); `path`/`tag`/`title` params — mirrors `GET /notes`.           |
| `get_note`        | Full content of one note by id, including lock status — mirrors `GET /notes/{id}`.                                            |
| `search_notes`    | Full-text search with `<mark>` snippets; `path`/`tag` params — mirrors `GET /search`.                                         |
| `create_note`     | Create a note; accepts `path` — mirrors `POST /notes`.                                                                        |
| `update_note`     | Update a note under optimistic concurrency (`version` required); accepts `path` — mirrors `PUT /notes/{id}`.                  |
| `move_note`       | Change only a note's `path` under the same version/lock rules as `update_note`; broadcasts `action: "moved"`.                 |
| `append_to_note`  | Server-side read-append-write; retries on a lost version race — mirrors `POST /notes/{id}/append`.                            |
| `get_backlinks`   | Notes whose content links to this note — mirrors `GET /notes/{id}/backlinks`.                                                 |
| `delete_note`     | Delete a note — mirrors `DELETE /notes/{id}`.                                                                                 |
| `create_folder`   | Create an empty folder (idempotent, no error if it already exists) — mirrors `POST /notes/tree`.                              |
| `request_upload`  | Reserve a token-authenticated upload slot; returns `upload_url`/`token`/`expires_at` for a `PUT /notes/file-uploads/{token}`. |
| `finalize_upload` | Place a completed upload (see `request_upload`) into the vault — the same write path `POST /notes/files` uses.                |

Every successful call returns both a `content[0].text` (JSON string)
and an identical `structuredContent` object. Domain failures (not
found, version conflict, locked, validation, insufficient scope) come
back as an ordinary JSON-RPC result with `isError: true` — never as a
JSON-RPC protocol error — so a client can tell "the server is broken"
apart from "the operation was refused". Every successful write
broadcasts the same `changed` event over `/ws` that the equivalent
REST call would, with `by` set to the calling actor.

### Security

Run the server behind HTTPS wherever it's reachable over an untrusted
network: the consent form submits the workspace API key over that
connection, with the same exposure as the `Authorization` header on
every other endpoint.

---

## Versioning compatibility

The API is forward-compatible with future CRDT-based editing:

- The `version` field on a note will continue to be a monotonically
  increasing counter.
- `changed` events will continue to fire at version bumps.
- New event types and message kinds will be added without renaming
  existing ones; clients SHOULD ignore unknown `type` values.
