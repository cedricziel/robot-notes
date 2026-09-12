## MODIFIED Requirements

### Requirement: Every HTTP request requires a valid bearer token

Every HTTP endpoint SHALL require an `Authorization: Bearer <key>` header whose value matches the configured key exactly (constant-time comparison), except the following unauthenticated paths: `GET /healthz`; `GET /ws` (authenticates in-protocol); `GET /invites/{token}/onboarding.txt` (the token is the credential); `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-protected-resource/mcp`, and `GET /.well-known/oauth-authorization-server` (public discovery documents); `POST /oauth/register`, `GET /oauth/authorize`, `POST /oauth/authorize`, `POST /oauth/token`, and `POST /oauth/revoke` (OAuth endpoints with their own authentication rules). `/mcp` SHALL accept either the configured key or an OAuth access token issued by this server, as specified by the `mcp-server` capability. Requests to any other path with a missing, malformed, or mismatched header SHALL be rejected with HTTP 401.

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

### Requirement: Bearer key rotation requires a server restart

The server SHALL load the bearer key once at startup and SHALL NOT expose any runtime mechanism (HTTP endpoint, WebSocket message, signal handler) to change it. Operators SHALL rotate the key by restarting the server with a new value. OAuth tokens issued by the server are separate credentials scoped to `/mcp` and do not change or replace the bearer key.

#### Scenario: No rotation endpoint exists

- **WHEN** any HTTP request is made to `/keys`, `/rotate`, or `/auth/rotate`
- **THEN** the server SHALL respond with HTTP 404

#### Scenario: OAuth endpoints do not alter the key

- **WHEN** an OAuth grant is completed and tokens are issued
- **THEN** `GET /notes` with the original configured key SHALL still respond with HTTP 200
