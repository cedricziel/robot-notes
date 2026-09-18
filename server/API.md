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
mismatch → `409 Conflict` with `{"error": "version_conflict", "current": {...}}`
(the full current note); locked-by-someone-else → `423 Locked` with
`{"error": "locked", "lock": {"holder", "expires_at"}}`.

### Error envelope

Every non-2xx response is a **flat** JSON object: a top-level `error`
string code, plus whatever sibling keys that code carries — never a
nested `{"error": {"code", "message", "details"}}` object. `error` is
always a bare string; test that shape, not its presence.

```json
{ "error": "not_found" }
```

```json
{
  "error": "version_conflict",
  "current": {
    "id": "01HM2A...",
    "title": "Meeting notes",
    "path": "Projects/Alpha",
    "content": "...",
    "version": 7,
    "created_at": "...",
    "updated_at": "...",
    "tags": ["urgent"]
  }
}
```

```json
{
  "error": "locked",
  "lock": { "holder": "alice", "expires_at": "2026-04-25T10:15:23Z" }
}
```

Some codes carry a `message` string instead (validation-style
failures):

```json
{ "error": "bad_request", "message": "limit must be a positive integer" }
```

Sibling keys by code:

| Code                     | Sibling key(s)      | Emitted by                                                                                            |
| ------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------ |
| `path_conflict`          | —                     | `POST /notes`, `PUT /notes/{id}`, `POST /notes/files`, `POST /databases`, `POST /databases/{id}/rows`, `PUT /databases/{id}` |
| `version_conflict`       | `current` (full note) | `PUT /notes/{id}`, `POST /notes/{id}/append`; `PUT /databases/{id}` (no `current`)                       |
| `locked`                 | `lock` (`holder`, `expires_at`) | `PUT /notes/{id}`, `DELETE /notes/{id}`, `POST /notes/{id}/append`, `POST`/`PUT`/`DELETE /notes/{id}/lock` |
| `unauthorized`           | —                     | any authenticated endpoint, missing/mismatching credential                                              |
| `insufficient_scope`     | —                     | any authenticated endpoint, OAuth token missing the required scope                                      |
| `not_found`              | —                     | `GET`/`PUT`/`DELETE /notes/{id}`, `GET /notes/{id}/backlinks`, `GET /notes/{id}/links`, `PATCH /notes/{id}/properties`, `PUT /notes/file-uploads/{token}`, `GET`/`PUT /databases/{id}`, `POST /databases/{id}/query`, `POST /databases/{id}/rows` |
| `lock_not_found`         | —                     | `PUT /notes/{id}/lock` (heartbeat with no active lock)                                                  |
| `precondition_required`  | `message`             | `PUT /notes/{id}` (missing `If-Match`)                                                                  |
| `bad_request`            | `message` (usually)   | malformed/invalid request body or query params, across most endpoints                                  |
| `validation_failed`      | `message`             | `POST /notes/{id}/append` (missing/blank `content`); `POST`/`PUT /notes/{id}` and `PATCH /notes/{id}/properties` (property schema violation); `POST /databases`, `PUT /databases/{id}`, `POST /databases/{id}/rows`, `POST /databases/{id}/query` (see [Databases](#databases)) |
| `missing_query`          | —                     | `GET /search` (`q` absent)                                                                              |
| `empty_query`            | —                     | `GET /search` (`q` whitespace-only)                                                                     |
| `invalid_query`          | —                     | `GET /search` (`q` not a valid FTS5 expression)                                                         |
| `payload_too_large`      | —                     | `POST /notes/files`, `PUT /notes/file-uploads/{token}` (over the configured max size)                   |
| `invalid_ttl`            | —                     | `POST /invites` (`ttl_seconds` out of range)                                                            |
| `invite_not_found`       | —                     | `DELETE /invites/{token}`, `GET /invites/{token}/onboarding.txt` (missing, revoked, or expired token)   |
| `invite_burned`          | —                     | `GET /invites/{token}/onboarding.txt` (already-consumed token)                                          |
| `method_not_allowed`     | —                     | any endpoint, unsupported HTTP method                                                                   |

No route currently emits `forbidden` or `internal_error`; an
unhandled server error surfaces as dart_frog's own default 500
response, not this envelope.

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
  "path": "Projects/Alpha",
  "properties": { "status": "todo" }
}
```

`title` defaults to empty string; `content` defaults to empty string;
`path` defaults to the empty string (vault root). `properties`
defaults to empty and is optional — see [Databases](#databases) for
the value encoding per property type; a note need not belong to a
database for `properties` to be set, but a value is only ever
validated against a database whose `source` covers the note's `path`.
A violation returns `400 Bad Request`
`{"error": "validation_failed", "message": "..."}`.

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
  "tags": [],
  "properties": { "status": "todo" }
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
  "properties": { "status": "done" },
  "lock": {
    "holder": "alice",
    "expires_at": "2026-04-25T10:15:23Z"
  }
}
```

`lock` is omitted when no editor lock is held. `properties` is every
frontmatter key that isn't one of the reserved/server-interpreted
keys (see [Databases](#databases)); it's `{}` for a note with no
extra frontmatter. A database definition note (`type: database`
frontmatter) additionally carries `"type": "database"` at the top
level — see `GET /databases/{id}` for its own dedicated shape.
`404 Not Found` (`{"error": "not_found"}`) if the id does not exist.

---

### `GET /notes/{id}/backlinks`

List notes whose content contains a `[[...]]` link resolving to this
note, most-recently-updated first. Authenticated. `404 Not Found`
(`{"error": "not_found"}`) if the id does not exist.

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
Found` (`{"error": "not_found"}`) if the id does not exist. `id` is
present only when the link
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

Request (any of `title`, `content`, `path`, `properties`; `content`
defaults to empty string when omitted, so a title/path-only rename
should still send the note's current `content` if it must be
preserved):

```json
{
  "title": "Meeting notes — Wed",
  "content": "…",
  "path": "Projects/Alpha",
  "properties": { "status": "done" }
}
```

Successful response `200 OK` (same shape as `GET /notes/{id}` minus
`lock`). A `title` change renames the underlying file; a `path` change
moves it — both under the same `If-Match`/lock rules as any other
write. If the note's title changes, every other note with a parsed
`[[...]]` link to the old title is rewritten to the new title as a
normal follow-up write (see "Links" in `STORAGE.md`). Moving a note
out from under a database's `source` drops it from that database's
rows on the database's next query; moving it under a covering
`source` — or adding a matching tag — picks it up the same way.

`properties` follows the same "omitted means unchanged, supplied
replaces every non-server-interpreted key" merge rule as
`Storage.update` (see `STORAGE.md`): supplying `properties` removes
any property key not present in it, while `tags`/`type`/`source`/
`views` are left alone. Validated the same way as on `POST /notes`; a
violation returns `400 Bad Request` `{"error": "validation_failed",
"message": "..."}` and the write does not happen. To set/unset a
handful of keys without the "supplied replaces the rest" behavior, use
`PATCH /notes/{id}/properties` instead.

Failure modes:

| Status                       | Body                                                              | Meaning                                                          |
| ---------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `428 Precondition Required`  | `{"error": "precondition_required", "message": "..."}`             | `If-Match` header missing.                                          |
| `400 Bad Request`            | `{"error": "bad_request", "message": "..."}`                       | `If-Match` isn't an integer, body isn't JSON/a JSON object, or an invalid `path`/`title`/`content`. |
| `400 Bad Request`            | `{"error": "validation_failed", "message": "..."}`                 | A `properties` value fails a covering database's schema.             |
| `404 Not Found`              | `{"error": "not_found"}`                                            | No note with this id.                                                |
| `409 Conflict`               | `{"error": "version_conflict", "current": {...full note...}}`      | `If-Match` no longer matches the note's current version.             |
| `409 Conflict`               | `{"error": "path_conflict"}`                                        | The resolved `path` collides with a different note.                  |
| `423 Locked`                 | `{"error": "locked", "lock": {"holder", "expires_at"}}`             | Another actor holds the editor lock.                                  |

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

| Status                | Body                                                          | Meaning                                    |
| --------------------- | ---------------------------------------------------------------- | --------------------------------------------- |
| `400 Bad Request`     | `{"error": "bad_request", "message": "..."}`                     | Body isn't JSON, or isn't a JSON object.       |
| `400 Bad Request`     | `{"error": "validation_failed", "message": "..."}`               | `content` is missing or blank.                 |
| `404 Not Found`       | `{"error": "not_found"}`                                          | No note with this id.                          |
| `409 Conflict`        | `{"error": "version_conflict", "current": {...full note...}}`    | Every retry attempt lost the version race.     |
| `423 Locked`          | `{"error": "locked", "lock": {"holder", "expires_at"}}`           | Another actor holds the editor lock.           |

Successful writes broadcast `changed { id, version, by, action: "updated" }`.

---

### `DELETE /notes/{id}`

Delete a note. Authenticated. Returns `204 No Content`. Broadcasts
`changed { id, version: <last>, by, action: "deleted" }`. Deleting a
note while it is locked by someone else returns `423 Locked` with
`{"error": "locked", "lock": {"holder", "expires_at"}}`. `404 Not
Found` (`{"error": "not_found"}`) if the id does not exist.

---

### `PATCH /notes/{id}/properties`

Set and/or unset frontmatter property keys on a note without touching
its body — no `If-Match` needed, and it ignores the editor lock (a
property patch is meant to be safe for an automation to fire even
while a human has the note open). See "Property encodings" and
"Reserved and built-in keys" under [Databases](#databases) below for
what may be set.

Request:

```json
{
  "set": { "status": "done", "priority": 2 },
  "unset": ["blocked_by"]
}
```

At least one of `set`/`unset` must be non-empty; a key present in
both is rejected. `set`ting a key to `null` is equivalent to
`unset`ting it. Every value in `set` is validated against every
database whose `source` currently covers this note — a violation of
any of them fails the whole patch with `400 Bad Request`
`{"error": "validation_failed", "message": "..."}` and the file is
left untouched.

Successful response `200 OK` (same shape as `GET /notes/{id}` minus
`lock`), reflecting the merged properties and bumped `version`.
Broadcasts `changed { id, version, by, action: "updated" }`.

Failure modes:

| Status            | Body                                                | Meaning                                                          |
| ----------------- | ---------------------------------------------------- | ----------------------------------------------------------------- |
| `400 Bad Request` | `{"error": "bad_request", "message": "..."}`         | Body isn't JSON, isn't a JSON object, or `set`/`unset` are the wrong shape. |
| `400 Bad Request` | `{"error": "validation_failed", "message": "..."}`   | Both `set`/`unset` empty, a key in both, a reserved/built-in/server-interpreted key, or a schema violation. |
| `404 Not Found`   | `{"error": "not_found"}`                             | No note with this id.                                             |

---

### `POST /notes/{id}/lock`

Acquire the editor lock for a note. Authenticated.

Request body: empty.

Response `200 OK`:

```json
{ "holder": "cedric", "expires_at": "2026-04-25T10:15:23Z" }
```

If another actor holds the lock and it has not expired → `423 Locked`:

```json
{
  "error": "locked",
  "lock": { "holder": "alice", "expires_at": "2026-04-25T10:15:23Z" }
}
```

The server never auto-steals — clients must wait for the TTL or for
the holder to release.

Lock TTL is ~60s; clients SHOULD heartbeat at half-TTL.

### `PUT /notes/{id}/lock`

Heartbeat the lock. Authenticated. Same actor only. Returns the
refreshed `{ holder, expires_at }`. `423 Locked`
(`{"error": "locked", "lock": {...}}`) if a different actor holds it.
`404 Not Found` (`{"error": "lock_not_found"}`) if no lock is
currently held on this note (already released or expired).

### `DELETE /notes/{id}/lock`

Release the lock. Authenticated. Idempotent for the holder (and for
anyone, once no lock is held). `423 Locked`
(`{"error": "locked", "lock": {...}}`) if a different actor holds it.
Returns `204 No Content`.

Lock state changes broadcast `lock { id, state: "acquired"|"released", holder }`
on the WebSocket.

---

### `GET /search?q=…`

Full-text search backed by SQLite FTS5. Authenticated.

Query parameters:

| Param   | Type   | Default | Notes                                                                         |
| ------- | ------ | ------- | ----------------------------------------------------------------------------- |
| `q`     | string | —       | Required — absent returns `400 {"error": "missing_query"}`; present but whitespace-only returns `400 {"error": "empty_query"}`. An invalid FTS5 expression returns `400 {"error": "invalid_query"}`. |
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

## Databases

A **database** is a note whose frontmatter carries `type: database`.
Its frontmatter also declares a `source` (which notes are its rows —
a folder, or a tag), a `properties` schema, and optionally saved
`views`. Every other note whose `path`/`tags` match that `source` is
one of its **rows**; a row's declared property values live in that
note's own frontmatter, set via `POST /databases/{id}/rows`,
`PUT /notes/{id}`, or `PATCH /notes/{id}/properties`. A definition
note is never itself a row, of its own database or any other's — even
one that fails to parse or fails validation and so is never actually
registered (see the "malformed definition" note below).

For the full data model see
`openspec/changes/add-databases/design.md` and
`openspec/specs/databases/spec.md`; this section documents the wire
surface.

### Definition frontmatter format

```yaml
---
id: "01HM2A..."
title: "Projects"
path: "Projects"
version: 3
created_at: "2026-04-25T10:14:23Z"
updated_at: "2026-04-25T10:20:00Z"
type: "database"
source:
  folder: "Projects"
  include_subfolders: true
properties:
  status:
    type: "select"
    options: ["todo", "doing", "done"]
  priority:
    type: "number"
  due:
    type: "date"
views:
  - name: "Board"
    type: "board"
    group_by: "status"
---
```

`source` defaults to the definition note's own folder (with
`include_subfolders: true`) when omitted — i.e. the simplest database
is just `type: database` in a note's frontmatter. `source` is exactly
one of:

```json
{ "folder": "Projects", "include_subfolders": true }
```

```json
{ "tag": "project" }
```

Every key in `properties` must match `^[a-z][a-z0-9_]*$`, be at most
64 characters, and not be one of the reserved keys `id`, `title`,
`path`, `version`, `created_at`, `updated_at`, `type`, `tags`,
`source`, `properties`, `views` (these are either storage-managed or
server-interpreted and can never be a property). Each property
declares a `type` (below), an optional `label`, `options` (required
for `select`/`multi_select`, a non-empty list of distinct strings),
and, for `relation`, an optional `database` (the id of the database
whose rows are valid targets — omitted means any note is valid).

Each view has a `name` (unique per definition, case-insensitively), a
`type` of `table`, `list`, or `board`, and optionally `filter`,
`sort`, `group_by`, and `properties` (an ordered column list — display
only, unenforced by the server). A `board` view requires `group_by`
naming a `select` property.

An invalid or malformed definition (bad key, unknown type, `select`
without `options`, `group_by` not a `select` property on a `board`
view, ...) is **not registered**: it never appears in `GET /databases`
or answers a query, and is logged by the server naming the note's
path — but the note itself still reads/writes/searches normally as an
ordinary note. Fix the frontmatter and it registers on the next write
(or the next server restart, which rebuilds the registry from the
search index without re-reading every file).

### Property encodings

| Type           | Wire value                                                            |
| -------------- | ----------------------------------------------------------------------- |
| `text`         | a string                                                                 |
| `number`       | a JSON number (not a numeric string)                                    |
| `checkbox`     | a JSON boolean                                                           |
| `date`         | `"YYYY-MM-DD"`, or a full ISO 8601 UTC timestamp string                  |
| `select`       | one of the property's declared `options` strings                        |
| `multi_select` | a list of declared `options` strings                                    |
| `relation`     | a list of `"[[Title]]"` / `"[[Title\|Alias]]"` wikilink strings          |
| `url`          | a string that parses as an absolute `http://`/`https://` URL             |

A missing key or an explicit `null` means the property is unset.
Setting an unset value happens by omitting the key (`PUT`) or naming
it in `unset` (`PATCH .../properties`) — sending an empty string does
not unset a `text` property, for instance.

A `relation` value is stored as the row's own outgoing links (so it
appears in `GET /notes/{id}/links` and drives backlinks the same way
a body `[[...]]` link would) and, when the property declares a
`database`, is validated: every listed title must resolve to a note
that is itself a row of that database, or the write is rejected.

### Reserved and built-in keys

`id`, `title`, `path`, `version`, `created_at`, `updated_at`, `type`,
`tags`, `source`, `properties`, `views` can never be declared as a
property key or set through a typed write (`POST .../rows`, `PUT
/notes/{id}`'s `properties`, `PATCH /notes/{id}/properties`) — `tags`
is managed by the ordinary note write path, and the rest are
storage/definition-managed. Of these, `title`, `path`, `tags`,
`created_at`, and `updated_at` are also **built-ins**: usable in a
filter, sort key, or `group_by` (as `builtin` types text/text/
multi_select/date/date respectively) even though they aren't declared
`properties`.

### Date semantics

A `date` value is either a bare calendar day (`"YYYY-MM-DD"`) or a
full UTC instant. `eq`/`neq` filters and ascending/descending sort
compare by **calendar day** regardless of which form is stored or
queried against; `gt`/`gte`/`lt`/`lte` compare the **instant**
(`YYYY-MM-DD` is treated as that day's `00:00:00.000Z`). The same day
rule applies to `created_at`/`updated_at` under `eq`/`neq`.

### The filter grammar

A filter is either a **condition** —

```json
{ "property": "status", "op": "eq", "value": "done" }
```

— or a **combinator**, nesting to any depth:

```json
{
  "and": [
    { "property": "status", "op": "neq", "value": "done" },
    { "or": [
        { "property": "priority", "op": "gte", "value": 2 },
        { "property": "due", "op": "lt", "value": "2026-05-01" }
    ] }
  ]
}
```

`op` is one of: `eq`, `neq`, `contains`, `not_contains`, `is_empty`,
`is_not_empty`, `gt`, `gte`, `lt`, `lte`. `is_empty`/`is_not_empty`
take no `value`; supplying one is a `validation_failed` error.
`is_empty` matches a missing key, an explicit `null`, an empty string,
or an empty list. Applicability by type:

| `op`                          | Applies to                                                                 |
| ------------------------------ | ----------------------------------------------------------------------------- |
| `eq` / `neq`                   | every type                                                                     |
| `contains` / `not_contains`    | `text`, `url`, `multi_select`, `relation`, `tags`, `title` (ASCII case-insensitive substring for text-like types; membership for list-like types) |
| `is_empty` / `is_not_empty`    | every type                                                                     |
| `gt` / `gte` / `lt` / `lte`    | `number`, `date` (including `created_at`/`updated_at`)                        |

Referencing an undeclared property, or applying an inapplicable
operator, returns `400 Bad Request`
`{"error": "validation_failed", "message": "..."}` before the query
runs.

### `GET /databases`

List every registered database. Authenticated.

```json
{
  "items": [
    {
      "id": "01HM2A...",
      "title": "Projects",
      "path": "Projects",
      "source": { "folder": "Projects", "include_subfolders": true },
      "row_count": 12
    }
  ]
}
```

`row_count` is computed at request time from the search index (not
cached on the definition).

---

### `POST /databases`

Create a new database: a note with `type: database` frontmatter.
Authenticated.

Request:

```json
{
  "title": "Projects",
  "path": "Projects",
  "source": { "folder": "Projects", "include_subfolders": true },
  "properties": {
    "status": { "type": "select", "options": ["todo", "doing", "done"] }
  },
  "views": [{ "name": "Board", "type": "board", "group_by": "status" }],
  "content": ""
}
```

`title` is required and non-blank; everything else is optional.
`source` defaults to the new note's own folder (`path`, defaulting to
the vault root) with subfolders included, exactly like an omitted
`source` in the raw frontmatter (above).

Response `201 Created`: the full definition, same shape as
`GET /databases/{id}` below.

Failure modes:

| Status              | Body                                                  | Meaning                                                    |
| ------------------- | -------------------------------------------------------- | -------------------------------------------------------------- |
| `400 Bad Request`   | `{"error": "bad_request", "message": "..."}`              | Body isn't JSON/a JSON object, or `title`/`source` is malformed. |
| `400 Bad Request`   | `{"error": "validation_failed", "message": "..."}`        | The definition fails schema/semantic validation.                |
| `409 Conflict`      | `{"error": "path_conflict"}`                              | The resolved `<path>/<title>.md` collides with another note.    |

---

### `GET /databases/{id}`

The full definition. Authenticated.

```json
{
  "id": "01HM2A...",
  "title": "Projects",
  "path": "Projects",
  "version": 3,
  "source": { "folder": "Projects", "include_subfolders": true },
  "properties": {
    "status": { "type": "select", "options": ["todo", "doing", "done"] },
    "priority": { "type": "number" }
  },
  "views": [
    { "name": "Board", "type": "board", "group_by": "status" }
  ],
  "created_at": "2026-04-25T10:14:23Z",
  "updated_at": "2026-04-25T10:20:00Z"
}
```

`404 Not Found` (`{"error": "not_found"}`) if the id doesn't name a
note, or names a note that isn't a *registered* database (not
`type: database`, or an invalid definition — see above).

---

### `PUT /databases/{id}`

Replace a database's `source`, `properties`, and/or `views` —
whichever sections are supplied are replaced **wholesale**, not
merged; an omitted section is left as-is. Authenticated. Requires
`If-Match: <version>`.

Request (any subset of `source`, `properties`, `views`):

```json
{
  "properties": {
    "status": { "type": "select", "options": ["todo", "doing", "done", "blocked"] }
  }
}
```

Removing a property from `properties` does not delete its values from
existing rows' frontmatter — it just stops being validated/surfaced by
this database until re-declared (or a differently-shaped value
becomes an `invalid` entry on query, see below). Response `200 OK`:
the updated full definition.

Failure modes: same shape as `PUT /notes/{id}` (`428`
`precondition_required`, `400` `bad_request`/`validation_failed`,
`404 not_found`, `409` `version_conflict`/`path_conflict`).

---

### `POST /databases/{id}/query`

Query a database's rows. Authenticated — needs only `notes:read`
(every other write-shaped database endpoint needs `notes:write`).

Request (every field optional):

```json
{
  "view": "Board",
  "filter": { "property": "status", "op": "neq", "value": "done" },
  "sort": [{ "property": "priority", "direction": "desc" }],
  "group_by": "status",
  "limit": 50,
  "after": "eyJz..."
}
```

`view` names one of the definition's saved views; a request field
(`filter`/`sort`/`group_by`) replaces that view's corresponding field
rather than merging with it. With no `view` and no override fields,
the first declared view is used as the default, if any. `sort` is a
list of `{"property","direction":"asc"|"desc"}`, applied stably with
`id asc` as the final tie-break and unset values sorted last in
either direction. `limit` defaults to 50, must be in `[1, 200]`.
`after` is an opaque cursor from a previous page's `next_cursor`; a
cursor from a different sort spec is rejected.

Response `200 OK`:

```json
{
  "items": [
    {
      "id": "01HM2B...",
      "title": "Alpha",
      "path": "Projects/Alpha",
      "version": 5,
      "created_at": "...",
      "updated_at": "...",
      "tags": [],
      "properties": { "status": "doing", "priority": 2 },
      "invalid": []
    }
  ],
  "next_cursor": null,
  "groups": [
    { "value": "todo", "count": 3 },
    { "value": "doing", "count": 1 },
    { "value": "done", "count": 0 },
    { "value": null, "count": 0 }
  ]
}
```

An item's `content` is never included (fetch it via `GET
/notes/{id}`). `properties` holds only declared keys present on the
row; `invalid` lists any of those whose stored value fails the
property's declared type (kept in `properties`, not dropped — a
hand-edited bad value is reported, not hidden). `groups` is present
only when a `group_by` is in effect: for a `select` property, every
declared option appears in declaration order with a zero count where
unused, plus a trailing `null` bucket for unset values; for any other
groupable type, groups are the distinct present values in ascending
order, likewise with a trailing `null` bucket.

Failure modes:

| Status              | Body                                                | Meaning                                          |
| -------------------- | ------------------------------------------------------ | ----------------------------------------------------- |
| `400 Bad Request`    | `{"error": "validation_failed", "message": "..."}`      | Unknown `view`, malformed `filter`/`sort`, bad `limit`, bad `after` cursor, or a filter referencing an undeclared property/inapplicable op. |
| `404 Not Found`      | `{"error": "not_found"}`                                | No registered database with this id.                  |

---

### `POST /databases/{id}/rows`

Create a new row: a note whose properties are validated against the
database's schema before anything is written. Authenticated.

Request:

```json
{
  "title": "Beta",
  "properties": { "status": "todo", "priority": 1 },
  "content": "",
  "path": "Projects/Beta"
}
```

`title` is required and non-blank. For a folder `source`, `path`
defaults to the source folder and must fall under it (with
subfolders, if `include_subfolders`); a `path` outside it is
rejected. For a tag `source`, `path` defaults to the vault root and
the source tag is added to the new note automatically.

Response `201 Created`:

```json
{
  "id": "01HM2C...",
  "title": "Beta",
  "path": "Projects/Beta",
  "content": "",
  "version": 1,
  "created_at": "...",
  "updated_at": "...",
  "tags": [],
  "properties": { "status": "todo", "priority": 1 }
}
```

Failure modes:

| Status              | Body                                                | Meaning                                              |
| -------------------- | ------------------------------------------------------ | ---------------------------------------------------------- |
| `400 Bad Request`    | `{"error": "bad_request", "message": "..."}`            | Body isn't JSON/a JSON object, or `title` is missing/blank.  |
| `400 Bad Request`    | `{"error": "validation_failed", "message": "..."}`      | A property violates the schema, or `path` falls outside the source folder. |
| `404 Not Found`      | `{"error": "not_found"}`                                | No registered database with this id.                        |
| `409 Conflict`       | `{"error": "path_conflict"}`                            | The resolved `<path>/<title>.md` collides with another note. |

Successful writes broadcast `changed { id, version: 1, by, action: "created" }`
the same as `POST /notes`.

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
for an already-consumed (burned) invite — its record still exists, so
revoking it still returns `204`. An unknown or already-revoked token
returns `404 Not Found` (`{"error": "invite_not_found"}`).

### `GET /invites/{token}/onboarding.txt`

Public, **single-use** bootstrap endpoint. **No `Authorization`
header** — the URL itself is the credential. Returns
`text/plain; charset=utf-8` with a parseable bundle:

```
ROBOT_NOTES_BASE_URL=https://notes.example.com
ROBOT_NOTES_API_KEY=rn_your_secret
ROBOT_NOTES_ACTOR=research-bot
```

The first successful fetch sets `burned_at`; subsequent fetches on
that token return `410 Gone` with `{"error": "invite_burned"}`. A
missing, revoked, or expired token returns `404 Not Found` with
`{"error": "invite_not_found"}` (expiry is not distinguished from
"never existed" on the wire).

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

`tools/list` always returns the same nineteen tools, regardless of
scope (scope is enforced per call, not per listing):

| Tool               | What it does                                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `list_notes`       | Paginated note metadata (id, title, path, version, timestamps); `path`/`tag`/`title` params — mirrors `GET /notes`.           |
| `get_note`         | Full content of one note by id, including lock status and `properties` — mirrors `GET /notes/{id}`.                          |
| `search_notes`     | Full-text search with `<mark>` snippets; `path`/`tag` params — mirrors `GET /search`.                                         |
| `create_note`      | Create a note; accepts `path` and `properties` — mirrors `POST /notes`.                                                       |
| `update_note`      | Update a note under optimistic concurrency (`version` required); accepts `path` and `properties` — mirrors `PUT /notes/{id}`. |
| `move_note`        | Change only a note's `path` under the same version/lock rules as `update_note`; broadcasts `action: "moved"`.                 |
| `append_to_note`   | Server-side read-append-write; retries on a lost version race — mirrors `POST /notes/{id}/append`.                            |
| `get_backlinks`    | Notes whose content links to this note — mirrors `GET /notes/{id}/backlinks`.                                                 |
| `delete_note`      | Delete a note — mirrors `DELETE /notes/{id}`.                                                                                 |
| `create_folder`    | Create an empty folder (idempotent, no error if it already exists) — mirrors `POST /notes/tree`.                              |
| `request_upload`   | Reserve a token-authenticated upload slot; returns `upload_url`/`token`/`expires_at` for a `PUT /notes/file-uploads/{token}`. |
| `finalize_upload`  | Place a completed upload (see `request_upload`) into the vault — the same write path `POST /notes/files` uses.                |
| `list_databases`   | Every registered database with id/title/path/source/`row_count` — mirrors `GET /databases`.                                  |
| `get_database`     | One database's full definition (properties with types/options, views) by id — mirrors `GET /databases/{id}`.                 |
| `create_database`  | Create a database (a `type: database` note); accepts `source`/`properties`/`views` — mirrors `POST /databases`.              |
| `update_database`  | Replace a database's `source`/`properties`/`views` wholesale under optimistic concurrency — mirrors `PUT /databases/{id}`.    |
| `query_database`   | Query a database's rows by saved view or filter/sort/group_by — mirrors `POST /databases/{id}/query`. Read-scope only.        |
| `create_row`       | Create a validated row (note) in a database — mirrors `POST /databases/{id}/rows`.                                            |
| `update_properties`| Set/unset frontmatter property keys without touching the body or requiring a version — mirrors `PATCH /notes/{id}/properties`. |

`create_database`, `update_database`, `create_row`, and
`update_properties`'s descriptions embed the same property-value
encoding table as [Databases](#databases) above; `query_database`'s
description embeds the same filter grammar.

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
