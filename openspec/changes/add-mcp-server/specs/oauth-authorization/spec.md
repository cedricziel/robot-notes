## Purpose

Lets any MCP client register itself and obtain access tokens for this server through standard OAuth 2.1 discovery, Dynamic Client Registration, and the authorization-code flow, so the workspace owner can connect agents without sharing the static API key.

## ADDED Requirements

### Requirement: Server resolves a single public base URL

The server SHALL derive one absolute public base URL (`<base>`, scheme plus host plus optional port, no trailing slash, no path) used for OAuth metadata, redirects, and invite URLs. When `--public-url` or `ROBOT_NOTES_PUBLIC_URL` is set it SHALL be used verbatim after validation; the value SHALL be an absolute `http` or `https` URL with no path, query, or fragment, and an invalid value SHALL abort startup with an error naming both configuration mechanisms. When unset, `<base>` SHALL be built per request from the `X-Forwarded-Proto` header when present (else the request scheme) and the `Host` header, and the server SHALL log a startup warning stating that the public URL should be configured for any deployment that is not loopback-only, since request headers are then trusted for the OAuth issuer. The canonical MCP resource identifier SHALL be `<base>/mcp`.

#### Scenario: Configured public URL wins

- **WHEN** the server runs with `ROBOT_NOTES_PUBLIC_URL=https://notes.example.com` and a request arrives with `Host: 10.0.0.5:8080`
- **THEN** metadata documents SHALL use `https://notes.example.com` as `<base>`

#### Scenario: Derived from headers

- **WHEN** no public URL is configured and a request arrives with `Host: notes.example.com` and `X-Forwarded-Proto: https`
- **THEN** metadata documents SHALL use `https://notes.example.com` as `<base>`

#### Scenario: Unset public URL warns at startup

- **WHEN** the server starts without `--public-url` or `ROBOT_NOTES_PUBLIC_URL`
- **THEN** the startup log SHALL contain a warning naming `ROBOT_NOTES_PUBLIC_URL`

#### Scenario: Invalid public URL aborts startup

- **WHEN** the server is started with `--public-url notes.example.com/app`
- **THEN** it SHALL exit non-zero with a message mentioning `--public-url` and `ROBOT_NOTES_PUBLIC_URL`

### Requirement: Protected resource metadata is published

`GET /.well-known/oauth-protected-resource` and `GET /.well-known/oauth-protected-resource/mcp` SHALL respond 200 without authentication with a JSON document containing `resource: "<base>/mcp"`, `authorization_servers: ["<base>"]`, `bearer_methods_supported: ["header"]`, `scopes_supported: ["notes:read", "notes:write"]`, and `resource_name: "robot-notes"`.

#### Scenario: Metadata without auth

- **WHEN** a client sends `GET /.well-known/oauth-protected-resource/mcp` with no `Authorization` header
- **THEN** the response SHALL be 200 with `resource == "<base>/mcp"` and `authorization_servers == ["<base>"]`

#### Scenario: Root variant matches

- **WHEN** a client sends `GET /.well-known/oauth-protected-resource`
- **THEN** the body SHALL be identical to the `/mcp` variant

### Requirement: Authorization server metadata is published

`GET /.well-known/oauth-authorization-server` SHALL respond 200 without authentication with a JSON document containing `issuer: "<base>"`, `authorization_endpoint: "<base>/oauth/authorize"`, `token_endpoint: "<base>/oauth/token"`, `registration_endpoint: "<base>/oauth/register"`, `revocation_endpoint: "<base>/oauth/revoke"`, `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"]`, and `scopes_supported: ["notes:read", "notes:write"]`.

#### Scenario: Metadata document

- **WHEN** a client sends `GET /.well-known/oauth-authorization-server`
- **THEN** the response SHALL be 200 and `code_challenge_methods_supported` SHALL equal `["S256"]` and `registration_endpoint` SHALL equal `"<base>/oauth/register"`

### Requirement: Dynamic Client Registration mints public or confidential clients

`POST /oauth/register` SHALL accept, without authentication, a JSON body per RFC 7591. `redirect_uris` SHALL be a non-empty array of absolute URIs, each either `https` or `http` with host `localhost`, `127.0.0.1`, or `[::1]`; otherwise the server SHALL respond 400 with `{ "error": "invalid_redirect_uri" }`. `token_endpoint_auth_method` SHALL default to `none` and SHALL be one of `none`, `client_secret_post`, `client_secret_basic`; `grant_types` (default `["authorization_code", "refresh_token"]`) and `response_types` (default `["code"]`) SHALL be subsets of the supported sets; any other value SHALL yield 400 `{ "error": "invalid_client_metadata" }`. The response SHALL be 201 with `Cache-Control: no-store` containing `client_id` (opaque, at least 128 bits of entropy), `client_id_issued_at`, the echoed `redirect_uris`, `client_name`, `token_endpoint_auth_method`, `grant_types`, `response_types`, and, for confidential methods only, a `client_secret` with `client_secret_expires_at: 0`. The registration SHALL be persisted so it survives restart.

#### Scenario: Public client registration

- **WHEN** a client posts `{ "client_name": "Desk Assistant", "redirect_uris": ["https://agent.example/callback"] }`
- **THEN** the response SHALL be 201 with a `client_id`, `token_endpoint_auth_method: "none"`, and no `client_secret`

#### Scenario: Confidential client registration

- **WHEN** a client posts registration with `token_endpoint_auth_method: "client_secret_post"`
- **THEN** the response SHALL include a `client_secret` and `client_secret_expires_at: 0`

#### Scenario: Localhost redirect is allowed

- **WHEN** a client registers `redirect_uris: ["http://localhost:53421/callback"]`
- **THEN** the response SHALL be 201

#### Scenario: Plain http redirect is rejected

- **WHEN** a client registers `redirect_uris: ["http://agent.example/callback"]`
- **THEN** the response SHALL be 400 with `error == "invalid_redirect_uri"`

#### Scenario: Missing redirect URIs

- **WHEN** a client posts `{ "client_name": "x" }`
- **THEN** the response SHALL be 400 with `error == "invalid_redirect_uri"`

#### Scenario: Unsupported auth method

- **WHEN** a client posts registration with `token_endpoint_auth_method: "private_key_jwt"`
- **THEN** the response SHALL be 400 with `error == "invalid_client_metadata"`

### Requirement: Authorization endpoint validates the request and renders a consent page

`GET /oauth/authorize` SHALL be served without bearer authentication. If `client_id` is unknown or `redirect_uri` does not exactly match one of the client's registered URIs, the server SHALL respond 400 with an HTML error page and SHALL NOT redirect. Otherwise, if `response_type` is not `code` the server SHALL redirect to `redirect_uri` with `error=unsupported_response_type`; if the client's registered `response_types` does not include `code` it SHALL redirect with `error=unauthorized_client`; if `code_challenge` is missing or `code_challenge_method` is not `S256` it SHALL redirect with `error=invalid_request`; if `scope` names a value outside `notes:read notes:write` it SHALL redirect with `error=invalid_scope`; if `resource` is present and is not `<base>/mcp` it SHALL redirect with `error=invalid_target`; an omitted `resource` SHALL be treated as `<base>/mcp`. Error redirects SHALL echo `state` when supplied. A valid request SHALL respond 200 with an HTML consent form that displays the client's name and requested scopes, contains a password field `api_key`, a text field `actor` prefilled with the client name, and carries every authorization parameter forward to `POST /oauth/authorize`. A missing `scope` SHALL be treated as `notes:read notes:write`.

#### Scenario: Consent page renders

- **WHEN** a registered client opens `GET /oauth/authorize?client_id=<id>&redirect_uri=<registered>&response_type=code&code_challenge=<c>&code_challenge_method=S256&state=xyz&resource=<base>/mcp`
- **THEN** the response SHALL be 200 HTML containing the client name, an `api_key` password input, and an `actor` input

#### Scenario: Unregistered redirect URI does not redirect

- **WHEN** a request uses a registered `client_id` but a `redirect_uri` that was not registered
- **THEN** the response SHALL be 400 and SHALL NOT include a `Location` header

#### Scenario: Missing PKCE challenge

- **WHEN** a request omits `code_challenge`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=invalid_request` and `state=xyz`

#### Scenario: Client not registered for the code response type

- **WHEN** a client registered with `response_types: ["token"]` requests `response_type=code`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=unauthorized_client`

#### Scenario: Wrong resource

- **WHEN** a request carries `resource=https://other.example/mcp`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=invalid_target`

### Requirement: Consent submission proves ownership with the API key and mints a code

`POST /oauth/authorize` SHALL accept `application/x-www-form-urlencoded` fields: the authorization parameters plus `api_key` and `actor`. The server SHALL re-run the validations of the GET step. `api_key` SHALL be compared in constant time to the configured API key; on mismatch the server SHALL respond 200 with the consent form re-rendered showing an error and SHALL NOT mint a code. On success it SHALL mint an authorization code with at least 128 bits of entropy, valid for 10 minutes, single-use, bound to `client_id`, `redirect_uri`, `code_challenge`, the granted scope set, the resource (`<base>/mcp` when `resource` was omitted), and the trimmed `actor` (falling back to the client name, then `mcp-client`, when empty), then respond 302 to `redirect_uri` with query parameters `code`, `iss=<base>`, and `state` when supplied.

#### Scenario: Correct key redirects with a code

- **WHEN** the form is submitted with the configured API key, `actor=desk-assistant`, and `state=xyz`
- **THEN** the response SHALL be 302 whose `Location` starts with `redirect_uri` and contains `code=`, `state=xyz`, and `iss=<base>`

#### Scenario: Wrong key re-renders

- **WHEN** the form is submitted with `api_key=wrong`
- **THEN** the response SHALL be 200 HTML containing an error message and no `Location` header, and no authorization code SHALL exist

#### Scenario: Omitted resource still binds the token to /mcp

- **WHEN** the authorization request omitted `resource` and the resulting code is exchanged
- **THEN** the access token SHALL be accepted at `/mcp`

#### Scenario: Empty actor falls back to client name

- **WHEN** the form is submitted with `actor=` (empty) for a client named `Desk Assistant`
- **THEN** tokens issued from the resulting code SHALL act as `Desk Assistant`

### Requirement: Token endpoint exchanges codes with PKCE verification

`POST /oauth/token` SHALL accept `application/x-www-form-urlencoded` and SHALL be served without bearer authentication. Client authentication SHALL follow the client's registered method: `none` requires `client_id` in the body; `client_secret_post` requires `client_id` and `client_secret` in the body; `client_secret_basic` requires HTTP Basic credentials. A failed client authentication SHALL respond 401 `{ "error": "invalid_client" }`. Grant-type errors SHALL be evaluated in this order: a missing `grant_type` yields 400 `{ "error": "invalid_request" }`; a `grant_type` the server does not support yields 400 `{ "error": "unsupported_grant_type" }`; a supported `grant_type` absent from the client's registered `grant_types` yields 400 `{ "error": "unauthorized_client" }`. Additionally, and `refresh_token` SHALL be omitted from the response when the client's registered `grant_types` lacks `refresh_token`. For `grant_type=authorization_code` the server SHALL require `code`, `redirect_uri`, and `code_verifier`, and SHALL reject with 400 `{ "error": "invalid_grant" }` when the code is unknown, expired, already used, issued to a different client, bound to a different `redirect_uri`, when `BASE64URL(SHA256(code_verifier))` differs from the bound `code_challenge`, or when a supplied `resource` differs from the bound one. Reuse of an already-consumed code SHALL additionally revoke every token issued from that code. Success SHALL respond 200 with `Cache-Control: no-store` and JSON `{ access_token, token_type: "Bearer", expires_in: 3600, refresh_token, scope }`, where both tokens are opaque with at least 256 bits of entropy. Missing parameters SHALL yield 400 `{ "error": "invalid_request" }`; unknown `grant_type` SHALL yield 400 `{ "error": "unsupported_grant_type" }`.

#### Scenario: Successful exchange

- **WHEN** a public client posts `grant_type=authorization_code` with a fresh code, the matching `redirect_uri`, `client_id`, and the correct `code_verifier`
- **THEN** the response SHALL be 200 with `token_type == "Bearer"`, `expires_in == 3600`, a `refresh_token`, `scope == "notes:read notes:write"`, and header `Cache-Control: no-store`

#### Scenario: Wrong verifier

- **WHEN** the exchange is posted with an incorrect `code_verifier`
- **THEN** the response SHALL be 400 with `error == "invalid_grant"`

#### Scenario: Code reuse revokes the grant

- **WHEN** a code that was already exchanged is posted again
- **THEN** the response SHALL be 400 with `error == "invalid_grant"` and the access token from the first exchange SHALL thereafter be rejected at `/mcp` with 401

#### Scenario: Expired code

- **WHEN** a code minted more than 10 minutes ago is posted
- **THEN** the response SHALL be 400 with `error == "invalid_grant"`

#### Scenario: Confidential client with wrong secret

- **WHEN** a `client_secret_post` client posts the exchange with a wrong `client_secret`
- **THEN** the response SHALL be 401 with `error == "invalid_client"`

#### Scenario: Missing grant type

- **WHEN** a client posts to the token endpoint without `grant_type`
- **THEN** the response SHALL be 400 with `error == "invalid_request"`

#### Scenario: Grant type not registered for the client

- **WHEN** a client registered with `grant_types: ["authorization_code"]` posts `grant_type=refresh_token`
- **THEN** the response SHALL be 400 with `error == "unauthorized_client"`

#### Scenario: No refresh token for clients without the refresh grant

- **WHEN** a client registered with `grant_types: ["authorization_code"]` exchanges a code
- **THEN** the response SHALL be 200 without a `refresh_token` field

#### Scenario: Unsupported grant type

- **WHEN** a client posts `grant_type=password`
- **THEN** the response SHALL be 400 with `error == "unsupported_grant_type"`

### Requirement: Refresh tokens rotate and detect reuse

For `grant_type=refresh_token` the server SHALL require `refresh_token` and client authentication as above. A refresh token SHALL be valid for 30 days from issue. A valid refresh SHALL issue a new access token and a new refresh token, invalidate the presented refresh token, and respond with the same JSON shape as the code exchange. `scope` MAY narrow but SHALL NOT widen the grant's scope set; widening SHALL yield 400 `{ "error": "invalid_scope" }`. Presenting an unknown, expired, revoked, or already-rotated refresh token SHALL yield 400 `{ "error": "invalid_grant" }`; an already-rotated token SHALL additionally revoke every token in that grant.

#### Scenario: Refresh rotates

- **WHEN** a client posts a valid `refresh_token`
- **THEN** the response SHALL contain a new `access_token` and a `refresh_token` different from the presented one, and the presented refresh token SHALL be rejected on a subsequent refresh

#### Scenario: Rotated token reuse revokes the family

- **WHEN** a client refreshes twice with the same original refresh token
- **THEN** the second call SHALL respond 400 `invalid_grant` and the access token issued by the first refresh SHALL be rejected at `/mcp`

#### Scenario: Scope cannot widen

- **WHEN** a grant holds `notes:read` only and the refresh request asks for `scope=notes:read notes:write`
- **THEN** the response SHALL be 400 with `error == "invalid_scope"`

### Requirement: Access tokens are validated as bearer credentials for /mcp

An access token SHALL be accepted at `/mcp` only when it exists, is an access token (not a refresh token or code), is unexpired, is unrevoked, and was issued for resource `<base>/mcp`. Expired or revoked tokens SHALL be rejected with 401 and `WWW-Authenticate` carrying `error="invalid_token"`. Tokens SHALL be usable across server restarts. Only hashes of access tokens, refresh tokens, codes, and client secrets SHALL be persisted; raw secrets SHALL NOT be written to disk or logs.

#### Scenario: Expired access token

- **WHEN** the clock advances past `expires_in` and the client presents the old access token at `/mcp`
- **THEN** the response SHALL be 401 with `error="invalid_token"` in `WWW-Authenticate`

#### Scenario: Refresh token is not an access token

- **WHEN** a client presents its refresh token as the bearer credential at `/mcp`
- **THEN** the response SHALL be 401

#### Scenario: Token survives restart

- **WHEN** the server is stopped and restarted with the same data directory
- **THEN** an access token issued before the restart and still within its lifetime SHALL be accepted at `/mcp`

#### Scenario: Raw token is not on disk

- **WHEN** an access token is issued
- **THEN** no file under `<data-dir>/oauth/` SHALL contain the raw token string

### Requirement: Revocation endpoint

`POST /oauth/revoke` SHALL accept `application/x-www-form-urlencoded` with `token` and client authentication as for the token endpoint. Revoking an access token SHALL invalidate that token; revoking a refresh token SHALL invalidate the whole grant (its refresh token and every access token). The endpoint SHALL respond 200 with an empty body whether or not the token existed, and 401 `invalid_client` on failed client authentication.

#### Scenario: Revoke refresh token

- **WHEN** a client revokes its refresh token
- **THEN** the response SHALL be 200 and the grant's current access token SHALL be rejected at `/mcp`

#### Scenario: Unknown token is still 200

- **WHEN** a client revokes a token string that was never issued
- **THEN** the response SHALL be 200

### Requirement: Expired OAuth records are purged at startup

At startup the server SHALL delete persisted authorization codes and tokens whose expiry has passed, and SHALL log the count purged without logging any token material.

#### Scenario: Startup purge

- **WHEN** the data directory contains an expired code file and an expired access-token file and the server starts
- **THEN** both files SHALL be removed and unexpired files SHALL remain
