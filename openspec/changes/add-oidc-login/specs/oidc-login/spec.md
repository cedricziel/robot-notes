## Purpose

Lets a human prove their identity to this server's own OAuth consent step by
logging in through one externally configured OIDC provider, instead of
pasting the workspace's static API key.

## ADDED Requirements

### Requirement: OIDC login is configured as all three settings or none

The server SHALL support configuring OIDC login via `--oidc-issuer`/
`ROBOT_NOTES_OIDC_ISSUER`, `--oidc-client-id`/`ROBOT_NOTES_OIDC_CLIENT_ID`,
and `--oidc-client-secret`/`ROBOT_NOTES_OIDC_CLIENT_SECRET` (CLI flag takes
precedence over its environment variable, matching `--api-key`). OIDC login
SHALL be considered configured only when all three are present and
non-empty; if exactly one or two are set, the server SHALL refuse to start
with an error naming the missing setting(s). When none are set, OIDC login
SHALL be disabled and no behavior elsewhere in the server SHALL differ from
a build without this capability.

#### Scenario: Fully configured

- **WHEN** the server starts with `--oidc-issuer`, `--oidc-client-id`, and `--oidc-client-secret` all set
- **THEN** it SHALL start successfully with OIDC login enabled

#### Scenario: Unconfigured

- **WHEN** the server starts with none of the three settings present
- **THEN** it SHALL start successfully with OIDC login disabled, and `GET /.well-known/oauth-authorization-server` SHALL NOT advertise it

#### Scenario: Partially configured refuses to start

- **WHEN** the server starts with `--oidc-issuer` set but neither client ID nor secret set
- **THEN** it SHALL exit with a non-zero status and an error naming the missing settings

### Requirement: Issuer discovery is resolved and cached at startup

When configured, the server SHALL fetch `<issuer>/.well-known/openid-configuration` at startup and extract `authorization_endpoint`, `token_endpoint`, and `jwks_uri`. Startup SHALL fail with a non-zero exit and an error naming the issuer when the discovery document cannot be fetched or is missing any of these fields. The server SHALL refetch the referenced JWKS document (not the discovery document) when verifying an ID token signed by a key ID it does not currently hold cached, to tolerate the provider's key rotation without a restart.

#### Scenario: Discovery succeeds

- **WHEN** the configured issuer's discovery document is reachable and well-formed
- **THEN** the server SHALL start successfully with the discovered endpoints in use

#### Scenario: Discovery document unreachable

- **WHEN** the configured issuer does not respond to the discovery request
- **THEN** the server SHALL exit non-zero with an error naming the issuer

#### Scenario: Unknown signing key triggers a JWKS refresh

- **WHEN** an ID token's header names a key ID (`kid`) not present in the cached JWKS
- **THEN** the server SHALL refetch the JWKS document once before rejecting the token

### Requirement: Login flow redirects to the provider with PKCE, state, and nonce

Starting an OIDC login (from a pending `/oauth/authorize` consent request) SHALL generate a fresh PKCE code verifier/challenge pair, an opaque `state` value, and a `nonce`, persist them bound to the pending consent request for at most 10 minutes, and redirect the user agent to the provider's `authorization_endpoint` with `response_type=code`, the configured `client_id`, a server-controlled `redirect_uri`, `scope` including at minimum `openid`, and the generated `code_challenge` (`S256`), `state`, and `nonce`. Expiry of the pending request SHALL abandon the login and require the consent flow to be restarted.

#### Scenario: Redirect is well-formed

- **WHEN** a user starts OIDC login from a pending consent request
- **THEN** the server SHALL redirect to the provider's `authorization_endpoint` with `response_type=code`, `scope` containing `openid`, `code_challenge_method=S256`, a `state`, and a `nonce`

#### Scenario: Expired pending login is rejected

- **WHEN** the callback arrives more than 10 minutes after the login was started
- **THEN** the server SHALL respond with an error page and SHALL NOT complete the pending consent request

### Requirement: Callback exchanges the code and verifies the ID token before completing consent

The callback endpoint SHALL reject any request whose `state` does not match a pending login exactly, without revealing whether a similar `state` exists. On a state match, it SHALL exchange the authorization `code` at the provider's `token_endpoint` using the bound PKCE verifier and the configured client credentials, then verify the returned ID token: signature verification SHALL use only `RS256` or `ES256` against a key fetched from the provider's `jwks_uri` matching the token's `kid`, and SHALL reject tokens using `alg=none` or any other algorithm. The server SHALL additionally verify `iss` equals the configured issuer, `aud` includes the configured `client_id`, `exp` is in the future, and `nonce` matches the value bound to the pending login. When `aud` has more than one value, the server SHALL additionally require an `azp` claim equal to the configured `client_id`, rejecting the token when `azp` is absent or names a different client (OpenID Connect Core 1.0 §3.1.3.7). Any verification failure SHALL abandon the pending consent request and respond with an error page; it SHALL NOT complete consent or mint an authorization code. On success, the server SHALL complete the pending `/oauth/authorize` consent exactly as a valid `api_key` submission would, using the ID token's `name` claim (falling back to `email`, then to the token's `sub`) as the actor.

#### Scenario: Mismatched state is rejected

- **WHEN** the callback is invoked with a `state` value that does not match any pending login
- **THEN** the server SHALL respond with an error page and SHALL NOT exchange the code

#### Scenario: Successful verification completes consent

- **WHEN** the code exchange succeeds and the returned ID token has a valid `RS256` or `ES256` signature, correct `iss`, `aud`, unexpired `exp`, and matching `nonce`
- **THEN** the server SHALL mint an authorization code for the pending consent request, using the ID token's `name` (or `email`) claim as the actor

#### Scenario: Unsigned or none-alg token is rejected

- **WHEN** the returned ID token has `alg=none` or is otherwise unsigned
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Wrong issuer is rejected

- **WHEN** the returned ID token's `iss` does not equal the configured issuer
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Wrong audience is rejected

- **WHEN** the returned ID token's `aud` does not include the configured `client_id`
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Multi-valued audience with no azp is rejected

- **WHEN** the returned ID token's `aud` includes the configured `client_id` alongside another audience, and no `azp` claim is present
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Multi-valued audience with mismatched azp is rejected

- **WHEN** the returned ID token's `aud` includes the configured `client_id` alongside another audience, and `azp` names a different client
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Expired ID token is rejected

- **WHEN** the returned ID token's `exp` is in the past
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Nonce mismatch is rejected

- **WHEN** the returned ID token's `nonce` does not match the value bound to the pending login
- **THEN** the server SHALL reject it and SHALL NOT complete consent

#### Scenario: Missing name claim falls back to email, then sub

- **WHEN** the returned ID token has no `name` claim but has an `email` claim
- **THEN** the actor recorded for tokens minted from this login SHALL be the `email` value
