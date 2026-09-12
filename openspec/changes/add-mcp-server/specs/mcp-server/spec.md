## Purpose

Exposes the note workspace to any MCP-capable agent over the Streamable HTTP transport, so agents can use robot-notes as shared memory through a standard tool catalog instead of hand-written HTTP calls.

## ADDED Requirements

### Requirement: Server exposes a single stateless MCP endpoint at /mcp

The server SHALL serve the MCP Streamable HTTP transport at the single path `/mcp`. `POST /mcp` SHALL accept exactly one JSON-RPC 2.0 message per request and SHALL always answer with `Content-Type: application/json` (never `text/event-stream`). The server SHALL NOT issue an `Mcp-Session-Id` header and SHALL ignore one supplied by the client. Authentication (next requirement) SHALL run before the method check, so an unauthenticated request receives 401 regardless of method; for an authenticated caller, `GET /mcp` and `DELETE /mcp` SHALL respond `405 Method Not Allowed` with an `Allow: POST` header.

#### Scenario: POST returns a JSON body

- **WHEN** an authenticated client sends `POST /mcp` with `Accept: application/json, text/event-stream` and a valid `ping` request
- **THEN** the response status SHALL be 200 with `Content-Type: application/json` and a JSON-RPC result body

#### Scenario: GET is refused

- **WHEN** an authenticated client sends `GET /mcp` with `Accept: text/event-stream`
- **THEN** the response status SHALL be 405 with header `Allow: POST`

#### Scenario: Unauthenticated GET is 401, not 405

- **WHEN** a client sends `GET /mcp` without an `Authorization` header
- **THEN** the response status SHALL be 401 with a `WWW-Authenticate` header

#### Scenario: DELETE is refused

- **WHEN** an authenticated client sends `DELETE /mcp` with an `Mcp-Session-Id` header
- **THEN** the response status SHALL be 405

#### Scenario: Session header is ignored

- **WHEN** an authenticated client sends a valid `tools/list` request with header `Mcp-Session-Id: anything`
- **THEN** the response SHALL be 200 with the tool catalog and SHALL NOT include an `Mcp-Session-Id` header

### Requirement: /mcp requires a bearer credential and advertises its resource metadata on 401

Every request to `/mcp` SHALL carry `Authorization: Bearer <credential>`. The credential SHALL be accepted when it equals the configured static API key (constant-time comparison) OR when it is a valid, unexpired, unrevoked OAuth access token issued by this server for the resource `<base>/mcp`. Otherwise the server SHALL respond 401 with the JSON error envelope `{"error":"unauthorized"}` and a `WWW-Authenticate` header of the form `Bearer realm="robot-notes", resource_metadata="<base>/.well-known/oauth-protected-resource/mcp"`; when a credential was supplied but rejected the header SHALL additionally carry `error="invalid_token"`. Access tokens SHALL NOT be accepted from the query string.

#### Scenario: Missing credential

- **WHEN** a client sends `POST /mcp` without an `Authorization` header
- **THEN** the response SHALL be 401 and the `WWW-Authenticate` header SHALL contain `resource_metadata="<base>/.well-known/oauth-protected-resource/mcp"` and SHALL NOT contain `error=`

#### Scenario: Unknown token

- **WHEN** a client sends `POST /mcp` with `Authorization: Bearer not-a-real-token`
- **THEN** the response SHALL be 401 and the `WWW-Authenticate` header SHALL contain both `error="invalid_token"` and the `resource_metadata` attribute

#### Scenario: Static API key is accepted

- **WHEN** a client sends `POST /mcp` with `Authorization: Bearer <configured-key>` and a `ping` request
- **THEN** the response SHALL be 200

#### Scenario: OAuth access token is accepted

- **WHEN** a client completes the OAuth flow and sends `POST /mcp` with `Authorization: Bearer <access-token>` and a `ping` request
- **THEN** the response SHALL be 200

#### Scenario: Token in query string is rejected

- **WHEN** a client sends `POST /mcp?access_token=<valid-access-token>` without an `Authorization` header
- **THEN** the response SHALL be 401

### Requirement: Actor identity for MCP calls comes from the credential

When `/mcp` is authenticated with the static API key the actor SHALL be taken from the `X-Actor` header, defaulting to `unknown` as elsewhere. When it is authenticated with an OAuth access token the actor SHALL be the actor name captured at consent for that grant, and any `X-Actor` header SHALL be ignored.

#### Scenario: Static key uses X-Actor

- **WHEN** a client authenticated with the static key and `X-Actor: research-bot` calls the `create_note` tool
- **THEN** the broadcast `changed` event SHALL have `by: "research-bot"`

#### Scenario: OAuth token uses the consented actor

- **WHEN** a grant was consented with actor `desk-assistant` and the client calls `create_note` with that grant's access token and `X-Actor: spoofed`
- **THEN** the broadcast `changed` event SHALL have `by: "desk-assistant"`

### Requirement: Origin header is validated against the public origin

When a request to `/mcp` carries an `Origin` header, the server SHALL compare it to the server's public origin (scheme, host, port) and SHALL also accept loopback origins (`http://localhost[:port]`, `http://127.0.0.1[:port]`, `http://[::1][:port]`). Any other origin SHALL be rejected with 403 and the JSON error envelope `{"error":"forbidden"}` before the body is parsed. Requests without an `Origin` header SHALL be accepted.

#### Scenario: Foreign origin is rejected

- **WHEN** a client sends `POST /mcp` with `Origin: https://evil.example` and a valid bearer key
- **THEN** the response SHALL be 403

#### Scenario: Own origin is accepted

- **WHEN** the public URL is `https://notes.example.com` and a client sends `POST /mcp` with `Origin: https://notes.example.com`
- **THEN** the request SHALL proceed to JSON-RPC handling

#### Scenario: No Origin header is accepted

- **WHEN** a non-browser client sends `POST /mcp` without an `Origin` header
- **THEN** the request SHALL proceed to JSON-RPC handling

### Requirement: Protocol version negotiation

The server SHALL support MCP protocol versions `2025-03-26`, `2025-06-18`, and `2025-11-25`. On `initialize` the server SHALL echo the client's requested `protocolVersion` when it is supported and SHALL otherwise reply `2025-06-18`. When a request carries an `MCP-Protocol-Version` header naming an unsupported version the server SHALL respond 400 with the JSON error envelope `{"error":"unsupported_protocol_version"}`; a missing header SHALL be accepted.

#### Scenario: Supported version is echoed

- **WHEN** a client sends `initialize` with `protocolVersion: "2025-11-25"`
- **THEN** the result SHALL contain `protocolVersion: "2025-11-25"`

#### Scenario: Unknown version falls back

- **WHEN** a client sends `initialize` with `protocolVersion: "1999-01-01"`
- **THEN** the result SHALL contain `protocolVersion: "2025-06-18"`

#### Scenario: Unsupported header version is rejected

- **WHEN** a client sends any request with header `MCP-Protocol-Version: 2024-11-05`
- **THEN** the response SHALL be 400 with `{"error":"unsupported_protocol_version"}`

### Requirement: JSON-RPC framing and error mapping

The server SHALL parse the POST body as a single JSON-RPC 2.0 message. A body that is not valid JSON SHALL yield HTTP 400 with a JSON-RPC error (`code: -32700`, `id: null`). A body that is a JSON array (batch) or an object without `"jsonrpc":"2.0"` SHALL yield HTTP 400 with a JSON-RPC error (`code: -32600`). A notification or a client response SHALL be accepted with HTTP 202 and an empty body. A request naming an unknown method SHALL yield HTTP 200 with a JSON-RPC error (`code: -32601`). A request with invalid parameters SHALL yield HTTP 200 with a JSON-RPC error (`code: -32602`). Every response SHALL echo the request `id`.

#### Scenario: Malformed JSON

- **WHEN** an authenticated client posts the body `{not json`
- **THEN** the response SHALL be 400 with a JSON-RPC error whose `code` is -32700

#### Scenario: Batch is rejected

- **WHEN** an authenticated client posts `[{"jsonrpc":"2.0","id":1,"method":"ping"}]`
- **THEN** the response SHALL be 400 with a JSON-RPC error whose `code` is -32600

#### Scenario: Notification is acknowledged

- **WHEN** an authenticated client posts `{"jsonrpc":"2.0","method":"notifications/initialized"}`
- **THEN** the response SHALL be 202 with an empty body

#### Scenario: Unknown method

- **WHEN** an authenticated client posts a request with `method: "resources/list"`
- **THEN** the response SHALL be 200 with a JSON-RPC error whose `code` is -32601 and whose `id` equals the request id

#### Scenario: Unknown tool

- **WHEN** an authenticated client posts `tools/call` with `name: "no_such_tool"`
- **THEN** the response SHALL be 200 with a JSON-RPC error whose `code` is -32602

### Requirement: Initialize describes the server and its tool capability

`initialize` SHALL return `serverInfo` with `name: "robot-notes"` and the server's release version, `capabilities` containing `tools: { "listChanged": false }` and nothing else, and a non-empty `instructions` string explaining that notes are shared memory between humans and agents, that `search_notes` should be tried before creating a note, and that `append_to_note` is the safe way to add to an existing note.

#### Scenario: Initialize result shape

- **WHEN** an authenticated client sends `initialize`
- **THEN** the result SHALL contain `serverInfo.name == "robot-notes"`, `capabilities.tools.listChanged == false`, no `resources` or `prompts` capability, and a non-empty `instructions` string

#### Scenario: Ping

- **WHEN** an authenticated client sends `ping`
- **THEN** the result SHALL be an empty object

### Requirement: tools/list returns the fixed note tool catalog

`tools/list` SHALL return exactly these tools, each with a `description` and a JSON Schema `inputSchema` of type `object` declaring the listed properties and `required` set: `list_notes` (`limit` integer 1..200, `after` string), `get_note` (`id` required), `create_note` (`title` required, `content`), `update_note` (`id` and `version` required, `title`, `content`), `append_to_note` (`id` and `text` required), `delete_note` (`id` required), `search_notes` (`query` required, `limit` integer 1..200). The catalog SHALL be the same regardless of the caller's scopes. The result SHALL NOT include a `nextCursor`.

#### Scenario: Catalog contents

- **WHEN** an authenticated client sends `tools/list`
- **THEN** the result `tools` array SHALL contain exactly the seven names above, each with `inputSchema.type == "object"`

#### Scenario: Required fields are declared

- **WHEN** the client inspects the `update_note` entry
- **THEN** `inputSchema.required` SHALL equal `["id", "version"]`

### Requirement: Tool results carry text and structured content; domain failures are tool errors

Every successful `tools/call` SHALL return a result with `content` containing one `text` item holding the JSON-serialized payload and `structuredContent` holding the same payload as an object. Domain failures (note not found, version conflict, lock held by another actor, validation failure, insufficient scope) SHALL be returned as a result with `isError: true`, a `text` item beginning with the error code, and `structuredContent` containing `error` plus any details. They SHALL NOT be reported as JSON-RPC errors.

#### Scenario: Not found is a tool error

- **WHEN** a client calls `get_note` with an id that does not exist
- **THEN** the response SHALL be 200 with `result.isError == true` and `result.structuredContent.error == "not_found"`

#### Scenario: Success carries both content forms

- **WHEN** a client calls `create_note` with `title: "Inbox"`
- **THEN** `result.structuredContent.id` SHALL be a ULID and `result.content[0].text` SHALL parse as JSON with the same `id`

### Requirement: Read tools mirror the HTTP API

`list_notes` SHALL return `{ items: [{ id, title, version, created_at, updated_at }], next_cursor }` following the same pagination rules as `GET /notes` (`limit` defaults to 50; values outside 1..200 are rejected as invalid params). `get_note` SHALL return `{ id, title, content, version, created_at, updated_at, lock? }` with `lock` present only while an editor lock is active. `search_notes` SHALL return `{ items: [{ id, title, snippet, rank }] }` using the same ranking, snippet markup, and default limit (20) as `GET /search`; an empty or FTS-invalid `query` SHALL be a `validation_failed` tool error.

#### Scenario: Pagination cursor

- **WHEN** 3 notes exist and a client calls `list_notes` with `limit: 2`
- **THEN** the result SHALL contain 2 items and a non-null `next_cursor`, and calling again with `after: next_cursor` SHALL return the remaining note

#### Scenario: Search hit

- **WHEN** a note containing the word "budget" exists and a client calls `search_notes` with `query: "budget"`
- **THEN** the result `items` SHALL contain that note's id with a `snippet` containing `<mark>budget</mark>`

#### Scenario: Invalid search query

- **WHEN** a client calls `search_notes` with `query: "   "`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "validation_failed"`

### Requirement: Write tools enforce optimistic concurrency, locks, and broadcast changes

`create_note` SHALL create a note (empty `title` is a `validation_failed` tool error) and return the full note. `update_note` SHALL require `version` to equal the note's current version; on mismatch it SHALL return a `version_conflict` tool error whose `structuredContent` includes `current_version` and `current_content`; at least one of `title` or `content` SHALL be supplied, otherwise `validation_failed`. `delete_note` SHALL remove the note and return `{ id, deleted: true }`. `update_note`, `append_to_note`, and `delete_note` SHALL return a `locked` tool error with the current `holder` when another actor holds the editor lock. Every successful write SHALL broadcast the same `changed` event as the equivalent HTTP call, with `by` set to the MCP actor.

#### Scenario: Update with stale version

- **WHEN** a note is at version 3 and a client calls `update_note` with `version: 2`
- **THEN** the result SHALL have `isError == true`, `structuredContent.error == "version_conflict"`, and `structuredContent.current_version == 3`

#### Scenario: Update succeeds

- **WHEN** a note is at version 3 and a client calls `update_note` with `version: 3` and `content: "new"`
- **THEN** the result SHALL contain `version: 4` and a `changed` event with `action: "updated"` SHALL be broadcast

#### Scenario: Locked by another actor

- **WHEN** actor `alice` holds the lock on a note and an MCP client acting as `bob` calls `delete_note` on it
- **THEN** the result SHALL have `isError == true`, `structuredContent.error == "locked"`, and `structuredContent.holder == "alice"`

#### Scenario: Delete broadcasts

- **WHEN** a client calls `delete_note` on an unlocked note
- **THEN** the result SHALL be `{ id, deleted: true }` and a `changed` event with `action: "deleted"` SHALL be broadcast

### Requirement: append_to_note is a server-side read-modify-write

`append_to_note` SHALL read the note's current content, append `text` separated by a single newline when the existing content is non-empty and does not already end with a newline, and write it back at the current version. If the write loses a version race the server SHALL re-read and retry up to 3 times before returning a `version_conflict` tool error. The result SHALL be `{ id, version }` for the new version. Empty `text` SHALL be a `validation_failed` tool error.

#### Scenario: Append separates with a newline

- **WHEN** a note's content is `line one` and a client calls `append_to_note` with `text: "line two"`
- **THEN** the note's content SHALL become `line one\nline two` and the result `version` SHALL be one higher than before

#### Scenario: Append to empty note

- **WHEN** a note's content is empty and a client calls `append_to_note` with `text: "first"`
- **THEN** the note's content SHALL become `first`

#### Scenario: Concurrent appends both land

- **WHEN** two clients call `append_to_note` on the same note at the same time
- **THEN** both calls SHALL succeed and the final content SHALL contain both appended texts

### Requirement: Scopes gate write tools

OAuth access tokens carry a scope set drawn from `notes:read` and `notes:write`. Calls to `create_note`, `update_note`, `append_to_note`, or `delete_note` with a token lacking `notes:write` SHALL return an `insufficient_scope` tool error. Calls to read tools with a token lacking `notes:read` SHALL likewise return `insufficient_scope`. The static API key SHALL be treated as holding both scopes.

#### Scenario: Read-only token cannot write

- **WHEN** a grant was issued with scope `notes:read` only and the client calls `create_note`
- **THEN** the result SHALL have `isError == true` and `structuredContent.error == "insufficient_scope"`

#### Scenario: Static key has full access

- **WHEN** a client authenticated with the static API key calls `create_note`
- **THEN** the note SHALL be created

### Requirement: MCP endpoint is reachable when the web bundle is served

When the server serves the Flutter web bundle at `/`, requests to `/mcp`, `/oauth/*`, and `/.well-known/*` SHALL bypass the static bundle and reach their handlers.

#### Scenario: Static mode does not shadow /mcp

- **WHEN** the server runs with a web directory configured and a client sends `POST /mcp` with a valid key
- **THEN** the response SHALL be a JSON-RPC response, not `index.html`
