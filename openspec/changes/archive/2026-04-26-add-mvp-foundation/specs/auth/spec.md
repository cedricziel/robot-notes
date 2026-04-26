## ADDED Requirements

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

Every HTTP endpoint except `GET /healthz` SHALL require an `Authorization: Bearer <key>` header whose value matches the configured key exactly (constant-time comparison). Requests with a missing, malformed, or mismatched header SHALL be rejected with HTTP 401.

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

The server SHALL load the bearer key once at startup and SHALL NOT expose any runtime mechanism (HTTP endpoint, WebSocket message, signal handler) to change it. Operators SHALL rotate the key by restarting the server with a new value.

#### Scenario: No rotation endpoint exists

- **WHEN** any HTTP request is made to a path containing `/auth`, `/keys`, or `/rotate`
- **THEN** the server SHALL respond with HTTP 404
