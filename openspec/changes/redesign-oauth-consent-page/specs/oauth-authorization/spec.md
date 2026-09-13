## MODIFIED Requirements

### Requirement: Authorization endpoint validates the request and renders a consent page

`GET /oauth/authorize` SHALL be served without bearer authentication. If `client_id` is unknown or `redirect_uri` does not exactly match one of the client's registered URIs, the server SHALL respond 400 with an HTML error page and SHALL NOT redirect. Otherwise, if `response_type` is not `code` the server SHALL redirect to `redirect_uri` with `error=unsupported_response_type`; if the client's registered `response_types` does not include `code` it SHALL redirect with `error=unauthorized_client`; if `code_challenge` is missing or `code_challenge_method` is not `S256` it SHALL redirect with `error=invalid_request`; if `scope` names a value outside `notes:read notes:write` it SHALL redirect with `error=invalid_scope`; if `resource` is present and is not `<base>/mcp` it SHALL redirect with `error=invalid_target`; an omitted `resource` SHALL be treated as `<base>/mcp`. Error redirects SHALL echo `state` when supplied. A valid request SHALL respond 200 with an HTML consent form that displays a branding header naming this server's own host, the client's name and requested scopes, the full `redirect_uri` the user will be returned to, contains a password field `api_key`, a text field `actor` prefilled with the client name, carries every authorization parameter forward to `POST /oauth/authorize`, and includes a Cancel link next to the primary action that returns the browser to `redirect_uri` with `error=access_denied` (and `state`, when supplied) appended. A missing `scope` SHALL be treated as `notes:read notes:write`.

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

#### Scenario: The consent page names this server's host

- **WHEN** the consent page renders
- **THEN** the response body SHALL contain this server's own host, derived the same way as the OAuth issuer

#### Scenario: The consent page shows the redirect destination

- **WHEN** the consent page renders for a client registered with `redirect_uri=https://agent.example/callback`
- **THEN** the response body SHALL contain the full `https://agent.example/callback`

#### Scenario: Cancel returns to the client with access_denied

- **GIVEN** the consent page is showing for a request with `state=xyz`
- **WHEN** the user follows the Cancel link
- **THEN** the browser SHALL be sent to `redirect_uri` with `error=access_denied` and `state=xyz` appended to its existing query string, without contacting the server again
