## MODIFIED Requirements

### Requirement: Every HTTP request requires a valid bearer token

Every HTTP endpoint SHALL require an `Authorization: Bearer <credential>` header, except the following unauthenticated paths: `GET /healthz`; `GET /ws` (authenticates in-protocol); `GET /invites/{token}/onboarding.txt` (the token is the credential); `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-protected-resource/mcp`, and `GET /.well-known/oauth-authorization-server` (public discovery documents); `POST /oauth/register`, `GET /oauth/authorize`, `POST /oauth/authorize`, `POST /oauth/token`, and `POST /oauth/revoke` (OAuth endpoints with their own authentication rules). The credential SHALL be accepted if it exactly matches the configured key (constant-time comparison), OR if it is a valid, unexpired, unrevoked OAuth access token issued by this server's own authorization server for resource `<base>` (the REST/WS audience, per the `oauth-authorization` capability — distinct from `<base>/mcp`) whose granted scopes are sufficient for the request: `notes:read` for safe (read-only) methods and `notes:write` for any method that creates, modifies, or deletes a note. A token issued for resource `<base>/mcp` SHALL NOT be accepted outside `/mcp`. A request bearing an otherwise-valid OAuth access token that lacks the scope required for the request SHALL be rejected with HTTP 403 and a JSON body `{ "error": "insufficient_scope" }`. A request with a missing, malformed header, or a credential that matches neither the configured key nor a valid, correctly-scoped, correctly-audienced OAuth access token, SHALL be rejected with HTTP 401.

`GET /notes/{id}` and `GET /search` double as the bundled Flutter web app's own client-side routes (the note view and the search screen), served at the same path as the API endpoint of the same name. A request to either path with no `Authorization` header SHALL still be served the web app (not rejected with 401) when its `Accept` header names `text/html` — the signature of a plain browser navigation (reload, bookmark, or shared link) rather than an API call. Absent that `Accept` header, a missing, malformed, or mismatched `Authorization` header on those two paths SHALL still be rejected with HTTP 401 as usual. Because the representation returned from these two paths depends on `Accept` and `Authorization`, every response from either path SHALL include a `Vary: Accept, Authorization` header, so a cache cannot replay the web app's `index.html` for a request that should get the JSON API response or vice versa.

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

#### Scenario: REST-audience OAuth token with sufficient scope opens the REST API

- **WHEN** a request to `GET /notes` carries a valid, unexpired OAuth access token issued for resource `<base>` and granted `notes:read`
- **THEN** the server SHALL respond with HTTP 200

#### Scenario: OAuth token without required scope is rejected

- **WHEN** a request to `POST /notes` carries a valid OAuth access token issued for resource `<base>` and granted only `notes:read`
- **THEN** the server SHALL respond with HTTP 403 and `error == "insufficient_scope"`

#### Scenario: Expired OAuth token is rejected

- **WHEN** a request to `GET /notes` carries an OAuth access token past its expiry
- **THEN** the server SHALL respond with HTTP 401

#### Scenario: OAuth token does not open the REST API

- **WHEN** a request to `GET /notes` carries a valid OAuth access token issued for resource `<base>/mcp` instead of the configured key
- **THEN** the server SHALL respond with HTTP 401

#### Scenario: Browser navigation to a note or search URL serves the web app without a key

- **WHEN** a request reaches `GET /notes/{id}` or `GET /search` with no `Authorization` header and `Accept: text/html,...`
- **THEN** the server SHALL respond with HTTP 200 and the web app's `index.html`, not a 401

#### Scenario: A non-browser request to those same paths still requires the key

- **WHEN** a request reaches `GET /notes/{id}` or `GET /search` with no `Authorization` header and an `Accept` header that does not name `text/html` (or no `Accept` header at all)
- **THEN** the server SHALL respond with HTTP 401, not the web app

#### Scenario: Dual-use paths always vary on Accept and Authorization

- **WHEN** a request reaches `GET /notes/{id}` or `GET /search`, regardless of whether it is served the web app or the JSON API response
- **THEN** the response SHALL include `Vary: Accept, Authorization`

### Requirement: Every WebSocket connection requires a valid bearer token

A client connecting to `/ws` SHALL authenticate within 2 seconds of connection by sending a JSON `auth` message containing either the bearer key or a valid, unexpired, unrevoked OAuth access token issued for resource `<base>` and granted at least `notes:read`. Connections that fail to authenticate within the window, send a credential matching neither form, present a token issued for resource `<base>/mcp` instead, or present an OAuth access token lacking `notes:read`, SHALL be closed with WebSocket close code 4001.

#### Scenario: Client authenticates immediately

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"<configured-key>","actor":"alice"}` within 2 seconds
- **THEN** the server SHALL accept the connection and emit `{"type":"auth_ok"}`

#### Scenario: Client authenticates with an OAuth access token

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"<valid OAuth access token with notes:read>"}` within 2 seconds
- **THEN** the server SHALL accept the connection, emit `{"type":"auth_ok"}`, and use the token's associated actor identity for that connection

#### Scenario: Client fails to authenticate in time

- **WHEN** a client connects to `/ws` and sends no message for 2 seconds
- **THEN** the server SHALL close the connection with code 4001 and reason `"auth_timeout"`

#### Scenario: Client sends wrong key

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"wrong","actor":"alice"}`
- **THEN** the server SHALL close the connection with code 4001 and reason `"auth_failed"`

#### Scenario: Client sends an OAuth token lacking read scope

- **WHEN** a client connects to `/ws` and sends `{"type":"auth","key":"<valid OAuth access token with no notes:read scope>"}`
- **THEN** the server SHALL close the connection with code 4001 and reason `"auth_failed"`

### Requirement: Clients declare a display identity via X-Actor

Clients authenticating with the static key SHOULD include an `X-Actor` HTTP header containing a free-text display name on every request; the server SHALL use this value as the actor identity in lock holders, presence lists, and `changed` event `by` fields, SHALL NOT validate or authenticate it, and SHALL substitute the literal string `"unknown"` when the header is absent or empty. Clients authenticating with any server-issued OAuth access token SHALL instead have their actor identity taken from the display name captured at grant time — for a grant completed via OIDC-backed login, the ID token's `name` claim (falling back to `email`, then `sub`); for a grant completed by pasting the static key at consent, the display name entered on the consent form — regardless of any `X-Actor` header sent; the server SHALL ignore `X-Actor` for every OAuth-authenticated request.

#### Scenario: Header is used as actor identity

- **WHEN** a request authenticated with the static key includes `X-Actor: Alice's laptop` and triggers a save
- **THEN** the resulting `changed` event SHALL include `"by": "Alice's laptop"`

#### Scenario: Missing header defaults to unknown

- **WHEN** a request authenticated with the static key omits `X-Actor` and triggers a save
- **THEN** the resulting `changed` event SHALL include `"by": "unknown"`

#### Scenario: Empty header defaults to unknown

- **WHEN** a request includes `X-Actor:` (empty value)
- **THEN** the server SHALL substitute `"unknown"`

#### Scenario: WebSocket actor is taken from the auth message

- **WHEN** a WebSocket client authenticates with `{"type":"auth","key":"...","actor":"summarizer-agent"}` using the static key
- **THEN** subsequent presence and lock events SHALL identify that connection as `"summarizer-agent"`

#### Scenario: OAuth-authenticated request uses the token's captured identity, not X-Actor

- **WHEN** a request authenticated with an OIDC-backed OAuth access token issued to `"Alice Example"` includes `X-Actor: someone-else` and triggers a save
- **THEN** the resulting `changed` event SHALL include `"by": "Alice Example"`, not `"someone-else"`

### Requirement: Bearer key rotation requires a server restart

The server SHALL load the bearer key once at startup and SHALL NOT expose any runtime mechanism (HTTP endpoint, WebSocket message, signal handler) to change it. Operators SHALL rotate the key by restarting the server with a new value. OAuth tokens issued by the server are separate credentials, scoped independently per grant, and do not change or replace the bearer key.

#### Scenario: No rotation endpoint exists

- **WHEN** any HTTP request is made to `/keys`, `/rotate`, or `/auth/rotate`
- **THEN** the server SHALL respond with HTTP 404

#### Scenario: OAuth endpoints do not alter the key

- **WHEN** an OAuth grant is completed and tokens are issued
- **THEN** `GET /notes` with the original configured key SHALL still respond with HTTP 200
