# auth Specification

## Purpose

TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.

## Requirements

### Requirement: Server requires a single bearer API key at startup

The server SHALL be configured at startup with exactly one bearer API key, supplied via either the `--api-key <key>` command-line argument or the `ROBOT_NOTES_API_KEY` environment variable. The CLI argument SHALL take precedence when both are provided. The server SHALL refuse to start if no key is configured.

#### Scenario: Server starts with --api-key argument

- **WHEN** the server is invoked with `--api-key rn_abc123`
- **THEN** it SHALL start successfully and accept requests bearing `Authorization: Bearer rn_abc123`

#### Scenario: Server starts with environment variable

- **WHEN** `ROBOT_NOTES_API_KEY=rn_abc123` is set and the server is invoked without `--api-key`
- **THEN** it SHALL start successfully and accept requests bearing `Authorization: Bearer rn_abc123`

#### Scenario: CLI argument overrides environment variable

- **WHEN** `ROBOT_NOTES_API_KEY=rn_env` is set and the server is invoked with `--api-key rn_arg`
- **THEN** the active key SHALL be `rn_arg`

#### Scenario: Server refuses to start without a key

- **WHEN** neither `--api-key` nor `ROBOT_NOTES_API_KEY` is provided
- **THEN** the server SHALL exit with a non-zero status code and an error message naming both configuration mechanisms

### Requirement: Every HTTP request requires a valid bearer token

Every HTTP endpoint SHALL require an `Authorization: Bearer <key>` header whose value matches the configured key exactly (constant-time comparison), except the following unauthenticated paths: `GET /healthz`; `GET /ws` (authenticates in-protocol); `GET /invites/{token}/onboarding.txt` (the token is the credential); `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-protected-resource/mcp`, and `GET /.well-known/oauth-authorization-server` (public discovery documents); `POST /oauth/register`, `GET /oauth/authorize`, `POST /oauth/authorize`, `POST /oauth/token`, and `POST /oauth/revoke` (OAuth endpoints with their own authentication rules). `/mcp` SHALL accept either the configured key or an OAuth access token issued by this server, as specified by the `mcp-server` capability. Requests to any other path with a missing, malformed, or mismatched header SHALL be rejected with HTTP 401.

`GET /notes/{id}`, `GET /search`, and `GET /databases/{id}` double as the bundled Flutter web app's own client-side routes (the note view, the search screen, and the database screen), served at the same path as the API endpoint of the same name. A request to either path with no `Authorization` header SHALL still be served the web app (not rejected with 401) when its `Accept` header names `text/html` — the signature of a plain browser navigation (reload, bookmark, or shared link) rather than an API call. Absent that `Accept` header, a missing, malformed, or mismatched `Authorization` header on those paths SHALL still be rejected with HTTP 401 as usual. Because the representation returned from these paths depends on `Accept` and `Authorization`, every response from any of them SHALL include a `Vary: Accept, Authorization` header, so a cache cannot replay the web app's `index.html` for a request that should get the JSON API response or vice versa.

#### Scenario: Valid bearer key is accepted

- **WHEN** a request includes `Authorization: Bearer <configured-key>`
- **THEN** the request SHALL proceed to the route handler

#### Scenario: Missing Authorization header is rejected

- **WHEN** a request includes no `Authorization` header
- **THEN** the server SHALL respond with HTTP 401 and a JSON body `{ "error": "unauthorized" }`

#### Scenario: Malformed Authorization header is rejected

- **WHEN** a request includes `Authorization: Basic <anything>` or `Authorization: <key>` (no `Bearer` prefix)
- **THEN** the server SHALL respond with HTTP 401

#### Scenario: Mismatched bearer key is rejected

- **WHEN** a request includes `Authorization: Bearer wrong-key`
- **THEN** the server SHALL respond with HTTP 401

#### Scenario: Health endpoint bypasses authentication

- **WHEN** an unauthenticated request reaches `GET /healthz`
- **THEN** the server SHALL respond with HTTP 200 regardless of `Authorization` header

#### Scenario: OAuth discovery bypasses authentication

- **WHEN** an unauthenticated request reaches `GET /.well-known/oauth-authorization-server`
- **THEN** the server SHALL respond with HTTP 200

#### Scenario: OAuth registration bypasses the static key

- **WHEN** an unauthenticated request reaches `POST /oauth/register` with a valid body
- **THEN** the server SHALL respond with HTTP 201

#### Scenario: OAuth token does not open the REST API

- **WHEN** a request to `GET /notes` carries a valid OAuth access token instead of the configured key
- **THEN** the server SHALL respond with HTTP 401

#### Scenario: Browser navigation to a note or search URL serves the web app without a key

- **WHEN** a request reaches `GET /notes/{id}`, `GET /search`, or `GET /databases/{id}` with no `Authorization` header and `Accept: text/html,...`
- **THEN** the server SHALL respond with HTTP 200 and the web app's `index.html`, not a 401

#### Scenario: A non-browser request to those same paths still requires the key

- **WHEN** a request reaches `GET /notes/{id}`, `GET /search`, or `GET /databases/{id}` with no `Authorization` header and an `Accept` header that does not name `text/html` (or no `Accept` header at all)
- **THEN** the server SHALL respond with HTTP 401, not the web app

#### Scenario: Dual-use paths always vary on Accept and Authorization

- **WHEN** a request reaches `GET /notes/{id}`, `GET /search`, or `GET /databases/{id}`, regardless of whether it is served the web app or the JSON API response
- **THEN** the response SHALL include `Vary: Accept, Authorization`

#### Scenario: The bare databases list is API-only

- **WHEN** a request reaches `GET /databases` with no `Authorization` header and `Accept: text/html`
- **THEN** the server SHALL respond with HTTP 401, as for any other API path

### Requirement: Every WebSocket connection requires a valid bearer token

A client connecting to `/ws` SHALL authenticate within 2 seconds of connection by sending a JSON `auth` message containing the bearer key. Connections that fail to authenticate within the window or send an incorrect key SHALL be closed with WebSocket close code 4001.

#### Scenario: Client authenticates immediately

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"<configured-key>","actor":"alice"}` within 2 seconds
- **THEN** the server SHALL accept the connection and emit `{"type":"auth_ok"}`

#### Scenario: Client fails to authenticate in time

- **WHEN** a client connects to `/ws` and sends no message for 2 seconds
- **THEN** the server SHALL close the connection with code 4001 and reason `"auth_timeout"`

#### Scenario: Client sends wrong key

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"wrong","actor":"alice"}`
- **THEN** the server SHALL close the connection with code 4001 and reason `"auth_failed"`

### Requirement: Clients declare a display identity via X-Actor

Clients SHOULD include an `X-Actor` HTTP header containing a free-text display name on every authenticated request. The server SHALL use this value as the actor identity in lock holders, presence lists, and `changed` event `by` fields. When the header is absent or empty the server SHALL substitute the literal string `"unknown"`. The server SHALL NOT validate or authenticate the value.

#### Scenario: Header is used as actor identity

- **WHEN** a request includes `X-Actor: Alice's laptop` and triggers a save
- **THEN** the resulting `changed` event SHALL include `"by": "Alice's laptop"`

#### Scenario: Missing header defaults to unknown

- **WHEN** a request omits `X-Actor` and triggers a save
- **THEN** the resulting `changed` event SHALL include `"by": "unknown"`

#### Scenario: Empty header defaults to unknown

- **WHEN** a request includes `X-Actor:` (empty value)
- **THEN** the server SHALL substitute `"unknown"`

#### Scenario: WebSocket actor is taken from the auth message

- **WHEN** a WebSocket client authenticates with `{"type":"auth","key":"...","actor":"summarizer-agent"}`
- **THEN** subsequent presence and lock events SHALL identify that connection as `"summarizer-agent"`

### Requirement: Bearer key rotation requires a server restart

The server SHALL load the bearer key once at startup and SHALL NOT expose any runtime mechanism (HTTP endpoint, WebSocket message, signal handler) to change it. Operators SHALL rotate the key by restarting the server with a new value. OAuth tokens issued by the server are separate credentials scoped to `/mcp` and do not change or replace the bearer key.

#### Scenario: No rotation endpoint exists

- **WHEN** any HTTP request is made to `/keys`, `/rotate`, or `/auth/rotate`
- **THEN** the server SHALL respond with HTTP 404

#### Scenario: OAuth endpoints do not alter the key

- **WHEN** an OAuth grant is completed and tokens are issued
- **THEN** `GET /notes` with the original configured key SHALL still respond with HTTP 200
