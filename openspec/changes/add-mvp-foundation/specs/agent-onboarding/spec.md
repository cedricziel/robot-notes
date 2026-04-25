## ADDED Requirements

### Requirement: Operator mints invite via authenticated POST /invites

A `POST /invites` endpoint SHALL allow a holder of the bearer API key to mint a single-use, time-limited invite. The request body MAY include an optional human-readable `label` (used as the suggested `X-Actor` for the agent and as a hint when listing invites) and an optional `ttl_seconds` (default 86400, maximum 2592000). The response SHALL be a JSON object containing `token`, `url`, `expires_at`, `single_use: true`, and the echoed `label`.

#### Scenario: Mint with default TTL

- **GIVEN** a server started with API key `rn_x`
- **WHEN** the client sends `POST /invites` with `Authorization: Bearer rn_x` and body `{}`
- **THEN** the response status SHALL be 201
- **AND** the body SHALL contain `token` (an opaque, URL-safe string with at least 128 bits of entropy), an absolute `url` of the form `<base>/invites/<token>/onboarding.txt`, an `expires_at` timestamp 24 hours in the future, and `single_use: true`

#### Scenario: Mint with custom label and TTL

- **WHEN** the client sends `POST /invites` with body `{ "label": "research-bot", "ttl_seconds": 3600 }`
- **THEN** the response SHALL include `label: "research-bot"` and `expires_at` one hour in the future

#### Scenario: TTL is clamped to maximum

- **WHEN** the client sends `POST /invites` with `ttl_seconds: 9999999`
- **THEN** the server SHALL respond 400 with an error code `invalid_ttl` (or clamp to 2592000 and document which behavior is normative — the spec requires the server to choose one and stick to it)

#### Scenario: Unauthenticated mint is rejected

- **WHEN** `POST /invites` is sent without `Authorization`
- **THEN** the response SHALL be 401 with the standard auth error envelope

### Requirement: Invites are stored as JSON files under data/invites/

Each minted invite SHALL be persisted as a JSON file at `data/invites/<token>.json`. The file SHALL contain at minimum: `token`, `label` (string, may be empty), `created_at`, `expires_at`, `single_use: true`, and either `burned_at: null` (not yet used) or `burned_at: <timestamp>` (used). Writes SHALL use the same atomic tmp+fsync+rename pattern the notes-storage capability uses.

#### Scenario: Mint creates a file

- **GIVEN** the data directory is empty
- **WHEN** the operator mints an invite returning `token: T`
- **THEN** `data/invites/T.json` SHALL exist on disk
- **AND** parsing it SHALL yield the same `token`, `expires_at`, and `label` returned in the API response
- **AND** `burned_at` SHALL be `null`

#### Scenario: Server restart preserves invites

- **GIVEN** an invite file exists at `data/invites/T.json` with `expires_at` in the future
- **WHEN** the server is restarted
- **THEN** the invite SHALL still be redeemable until it expires or is revoked

### Requirement: GET /invites lists active invites

A `GET /invites` endpoint (Bearer-protected) SHALL return a JSON array of all invite files currently on disk. Each entry SHALL include `token`, `label`, `created_at`, `expires_at`, and `burned_at`. Expired invites MAY appear in the list but SHALL be marked as such (e.g. an `expired: true` field), so an operator can see and clean up state.

#### Scenario: Listing returns minted invites

- **GIVEN** two invites have been minted
- **WHEN** the client `GET /invites` with the bearer key
- **THEN** the response SHALL be a JSON array of length 2 containing both `token`s

#### Scenario: Listing requires auth

- **WHEN** `GET /invites` is sent without `Authorization`
- **THEN** the response SHALL be 401

### Requirement: DELETE /invites/{token} revokes an invite

A `DELETE /invites/{token}` endpoint (Bearer-protected) SHALL remove the invite file from disk. The response SHALL be 204 on success and 404 if no such invite exists.

#### Scenario: Delete burns the invite immediately

- **GIVEN** an unburned invite exists at token `T`
- **WHEN** the operator sends `DELETE /invites/T` with the bearer key
- **THEN** the response SHALL be 204
- **AND** `data/invites/T.json` SHALL no longer exist
- **AND** any subsequent `GET /invites/T/onboarding.txt` SHALL return 404

#### Scenario: Delete of unknown token is 404

- **WHEN** `DELETE /invites/unknown-token` is sent
- **THEN** the response SHALL be 404 with error code `invite_not_found`

### Requirement: GET /invites/{token}/onboarding.txt is unauthenticated and single-use

The endpoint `GET /invites/{token}/onboarding.txt` SHALL be reachable without `Authorization`. On the first valid fetch the server SHALL respond 200 with `Content-Type: text/plain; charset=utf-8` carrying the onboarding bundle, and SHALL atomically set `burned_at` on the invite file before returning. On any subsequent fetch the server SHALL respond 410 Gone with an error envelope. If the invite is missing, expired, or already burned, the server SHALL respond 404 (missing/expired) or 410 (already burned) — never 200 with the bundle.

#### Scenario: First fetch returns the bundle and burns the invite

- **GIVEN** an unburned, unexpired invite exists at token `T`
- **WHEN** an unauthenticated `GET /invites/T/onboarding.txt` is sent
- **THEN** the response SHALL be 200 with `Content-Type: text/plain; charset=utf-8`
- **AND** the body SHALL contain the onboarding bundle (see next requirement)
- **AND** after the response is sent `data/invites/T.json` SHALL have `burned_at` set to the current timestamp

#### Scenario: Second fetch returns 410 Gone

- **GIVEN** invite `T` was successfully fetched once and is now burned
- **WHEN** any client fetches `GET /invites/T/onboarding.txt` again
- **THEN** the response SHALL be 410 with error code `invite_burned`

#### Scenario: Expired invite returns 404

- **GIVEN** an invite with `expires_at` in the past
- **WHEN** the onboarding endpoint is fetched
- **THEN** the response SHALL be 404 with error code `invite_not_found`

#### Scenario: Burn is atomic under concurrent fetches

- **GIVEN** two clients fetch `GET /invites/T/onboarding.txt` simultaneously
- **WHEN** the requests race
- **THEN** exactly one client SHALL receive 200 with the bundle
- **AND** the other SHALL receive 410 Gone

### Requirement: Onboarding bundle contains everything an agent needs

The `onboarding.txt` body SHALL be plain text (Markdown-compatible) containing, at minimum:

- A short human-readable intro identifying this as a robot-notes onboarding bundle.
- The server `base_url` (the same origin the request was served from).
- The shared `api_key` value (the same value the server was started with).
- A recommended `X-Actor` header value (defaulting to the invite's `label`, or `"agent"` if no label was set).
- A verification step the agent can run (e.g. `curl -H "Authorization: Bearer <key>" <base_url>/healthz`).
- An inline summary of the API surface: every endpoint listed in `notes-api`, the lock lifecycle from `lock-management`, the WebSocket protocol from `realtime-sync`, and the search endpoint from `search`. Enough that an LLM with no other context can begin making correct calls.
- A note that the bundle is single-use and that the URL has now been burned.

#### Scenario: Bundle includes the api key and base URL

- **WHEN** an agent fetches the bundle
- **THEN** the body SHALL contain the literal string of the configured API key
- **AND** SHALL contain the server's base URL (matching the `Host` header / configured base)

#### Scenario: Bundle includes API surface guide

- **WHEN** an agent fetches the bundle
- **THEN** the body SHALL document `GET /notes`, `POST /notes`, `GET/PUT/DELETE /notes/{id}`, the lock endpoints, `/search`, and `/ws` — enough for an agent to write a correct first request without reading external docs

#### Scenario: Bundle includes recommended X-Actor

- **GIVEN** an invite was minted with `label: "research-bot"`
- **WHEN** the bundle is fetched
- **THEN** it SHALL recommend `X-Actor: research-bot`

#### Scenario: Bundle is plain text

- **WHEN** the bundle is fetched
- **THEN** the response `Content-Type` SHALL start with `text/plain`
- **AND** the body SHALL NOT contain HTML tags that require rendering to be readable

### Requirement: Invite endpoints are excluded from CORS-credentialed paths

The unauthenticated `GET /invites/{token}/onboarding.txt` endpoint SHALL NOT include `Access-Control-Allow-Credentials: true` in its response, and SHALL NOT echo arbitrary `Origin` headers. The authenticated `/invites` management endpoints SHALL behave identically to other Bearer-protected endpoints with respect to CORS.

#### Scenario: Onboarding endpoint does not advertise credentials

- **WHEN** any browser issues `GET /invites/T/onboarding.txt` with an `Origin` header
- **THEN** the response SHALL NOT include `Access-Control-Allow-Credentials: true`

### Requirement: Invite secrets do not appear in logs

The server SHALL NOT log the full bearer API key, the invite `token`, or the body of any onboarding bundle. Log entries about invite operations MAY include the `label` and a truncated token prefix (e.g. first 8 characters) for diagnostics, but SHALL redact the rest.

#### Scenario: Mint logs do not include the full token

- **WHEN** an invite is minted and any log line records the operation
- **THEN** the log SHALL NOT contain the full token string
- **AND** SHALL NOT contain the API key

#### Scenario: Onboarding fetch logs do not include the bundle

- **WHEN** an agent fetches an onboarding bundle and the server logs the request
- **THEN** the log SHALL NOT contain the response body
