# Spec Delta

## MODIFIED Requirements

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
