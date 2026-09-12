## MODIFIED Requirements

### Requirement: Authorization server metadata is published

`GET /.well-known/oauth-authorization-server` SHALL respond 200 without authentication with a JSON document containing `issuer: "<base>"`, `authorization_endpoint: "<base>/oauth/authorize"`, `token_endpoint: "<base>/oauth/token"`, `registration_endpoint: "<base>/oauth/register"`, `revocation_endpoint: "<base>/oauth/revoke"`, `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"]`, and `scopes_supported: ["notes:read", "notes:write"]`. When OIDC login is configured (per the `oidc-login` capability), the document SHALL additionally include `"robotnotes_oidc_login_supported": true`; when not configured this field SHALL be omitted.

#### Scenario: Metadata document

- **WHEN** a client sends `GET /.well-known/oauth-authorization-server`
- **THEN** the response SHALL be 200 and `code_challenge_methods_supported` SHALL equal `["S256"]` and `registration_endpoint` SHALL equal `"<base>/oauth/register"`

#### Scenario: OIDC availability is advertised when configured

- **WHEN** the server is configured with an OIDC issuer, client ID, and client secret, and a client sends `GET /.well-known/oauth-authorization-server`
- **THEN** the response body SHALL contain `"robotnotes_oidc_login_supported": true`

#### Scenario: Field omitted when OIDC is not configured

- **WHEN** the server has no OIDC issuer configured and a client sends `GET /.well-known/oauth-authorization-server`
- **THEN** the response body SHALL NOT contain `robotnotes_oidc_login_supported`

### Requirement: Authorization endpoint validates the request and renders a consent page

`GET /oauth/authorize` SHALL be served without bearer authentication. If `client_id` is unknown or `redirect_uri` does not exactly match one of the client's registered URIs, the server SHALL respond 400 with an HTML error page and SHALL NOT redirect. Otherwise, if `response_type` is not `code` the server SHALL redirect to `redirect_uri` with `error=unsupported_response_type`; if the client's registered `response_types` does not include `code` it SHALL redirect with `error=unauthorized_client`; if `code_challenge` is missing or `code_challenge_method` is not `S256` it SHALL redirect with `error=invalid_request`; if `scope` names a value outside `notes:read notes:write` it SHALL redirect with `error=invalid_scope`; if `resource` is present and is neither `<base>/mcp` nor `<base>` it SHALL redirect with `error=invalid_target`; an omitted `resource` SHALL be treated as `<base>/mcp`. Error redirects SHALL echo `state` when supplied. A missing `scope` SHALL be treated as `notes:read notes:write`. A valid request SHALL respond 200 with an HTML consent form that displays the client's name and requested scopes and carries every authorization parameter forward to the identity-proving step. When OIDC login is NOT configured, that step is a password field `api_key` and a text field `actor` prefilled with the client name, submitted to `POST /oauth/authorize` as before. When OIDC login IS configured, that step SHALL instead be a link/button that starts the OIDC login flow defined by the `oidc-login` capability, with no `api_key` field rendered; a successful OIDC login completes the consent step and proceeds exactly as a correct `POST /oauth/authorize` submission would, using the identity's `name` (falling back to `email`) as the actor.

#### Scenario: Consent page renders

- **WHEN** OIDC login is not configured and a registered client opens `GET /oauth/authorize?client_id=<id>&redirect_uri=<registered>&response_type=code&code_challenge=<c>&code_challenge_method=S256&state=xyz&resource=<base>/mcp`
- **THEN** the response SHALL be 200 HTML containing the client name, an `api_key` password input, and an `actor` input

#### Scenario: Consent page renders an OIDC sign-in option when OIDC is configured

- **WHEN** OIDC login is configured and a registered client opens `GET /oauth/authorize` with a valid request
- **THEN** the response SHALL be 200 HTML containing a sign-in link that starts the OIDC login flow, and SHALL NOT contain an `api_key` password input

#### Scenario: Unregistered redirect URI does not redirect

- **WHEN** a request uses a registered `client_id` but a `redirect_uri` that was not registered
- **THEN** the response SHALL be 400 and SHALL NOT include a `Location` header

#### Scenario: Missing PKCE challenge

- **WHEN** a request omits `code_challenge`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=invalid_request` and `state=xyz`

#### Scenario: Client not registered for the code response type

- **WHEN** a client registered with `response_types: ["token"]` requests `response_type=code`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=unauthorized_client`

#### Scenario: REST/WS resource is accepted

- **WHEN** a request carries `resource=<base>` (no path)
- **THEN** the server SHALL respond 200 with the consent form, and a code later minted from this request SHALL be bound to resource `<base>`

#### Scenario: Wrong resource

- **WHEN** a request carries `resource=https://other.example/mcp`
- **THEN** the response SHALL be 302 to `redirect_uri` with `error=invalid_target`

### Requirement: Consent submission proves ownership with the API key and mints a code

`POST /oauth/authorize` SHALL accept `application/x-www-form-urlencoded` fields: the authorization parameters plus `api_key` and `actor`. This endpoint SHALL only be reachable when OIDC login is not configured, or as the internal completion step the server invokes itself after a successful OIDC login (per the `oidc-login` capability), which supplies the actor from the verified identity instead of a form field. The server SHALL re-run the validations of the GET step. When completing via the `api_key` field, it SHALL be compared in constant time to the configured API key; on mismatch the server SHALL respond 200 with the consent form re-rendered showing an error and SHALL NOT mint a code. On success it SHALL mint an authorization code with at least 128 bits of entropy, valid for 10 minutes, single-use, bound to `client_id`, `redirect_uri`, `code_challenge`, the granted scope set, the resource (`<base>/mcp` when `resource` was omitted), and the trimmed `actor` (falling back to the client name, then `mcp-client`, when empty — or, for an OIDC-completed consent, the verified identity's `name` falling back to `email`), then respond 302 to `redirect_uri` with query parameters `code`, `iss=<base>`, and `state` when supplied.

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

#### Scenario: Successful OIDC login completes consent

- **WHEN** OIDC login is configured, a consent request is pending, and the user completes the OIDC login flow successfully
- **THEN** the server SHALL mint a code bound to the verified identity's `name` (or `email`) as actor and respond 302 to `redirect_uri` with `code`, `iss=<base>`, and `state` when supplied, without any `api_key` ever being submitted

### Requirement: Access tokens are validated as bearer credentials for their bound resource

An access token SHALL be accepted as a bearer credential only when it exists, is an access token (not a refresh token or code), is unexpired, is unrevoked, and the resource it is presented to matches the resource it was issued for: a token issued for `<base>/mcp` SHALL be accepted only at `/mcp`; a token issued for `<base>` SHALL be accepted only by the REST API and WebSocket, per the `auth` capability. Expired or revoked tokens SHALL be rejected with 401 and `WWW-Authenticate` carrying `error="invalid_token"`. Tokens SHALL be usable across server restarts. Only hashes of access tokens, refresh tokens, codes, and client secrets SHALL be persisted; raw secrets SHALL NOT be written to disk or logs.

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

#### Scenario: Token minted for the REST/WS resource does not open /mcp

- **WHEN** a token issued for resource `<base>` is presented at `/mcp`
- **THEN** the response SHALL be 401
