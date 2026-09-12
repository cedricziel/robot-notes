## 1. Resource-audience widening in the existing OAuth server (PR 1)

No OIDC yet — this PR only teaches the already-built OAuth 2.1 server and
`bearerAuth()` to recognize a second resource (`<base>`, for REST/WS) and
enforce scope, so the OIDC PRs that follow have somewhere to land tokens.
Testable end-to-end today via the existing `api_key` consent form.

- [ ] 1.1 Write failing tests in `server/test/routes/oauth/authorize_test.dart`: `resource=<base>` (no path) is accepted on the GET step and round-trips through consent into a code bound to resource `<base>`; `resource=https://other.example` is still rejected with `invalid_target`
- [ ] 1.2 Extend the resource validator in `routes/oauth/authorize.dart` so 1.1 passes
- [ ] 1.3 Write failing tests in `server/test/src/oauth/token_store_test.dart` (or wherever resource is asserted): tokens minted from a `<base>`-resource code carry that resource; `lookupAccess` exposes it
- [ ] 1.4 Confirm/extend `OAuthToken`/`AuthorizationCode` records already carry `resource` end to end (per PR 3 of `add-mcp-server`) so 1.3 passes with no further store changes, or add the field if missing
- [ ] 1.5 Write failing tests in `server/test/src/auth_middleware_test.dart`: a valid, unexpired `<base>`-resource token with `notes:read` opens `GET /notes` (200); the same token without `notes:write` gets 403 `insufficient_scope` on `POST /notes`; a `<base>/mcp`-resource token is rejected on `GET /notes` (401); an expired `<base>`-resource token is rejected (401); the static key still works unchanged
- [ ] 1.6 Implement the second credential path in `bearerAuth()` (`server/lib/src/auth_middleware.dart`): accept a valid OAuth access token scoped and audienced for the request, scope-gate by HTTP method, reject cross-audience tokens, so 1.5 passes
- [ ] 1.7 Write failing tests in `server/test/src/ws/connection_test.dart` (or equivalent): a `/ws` `auth` message carrying a `<base>`-resource token with `notes:read` is accepted; one carrying a `<base>/mcp`-resource token, or one lacking `notes:read`, is closed 4001 `auth_failed`
- [ ] 1.8 Implement the second credential path for the `/ws` auth message so 1.7 passes
- [ ] 1.9 Write failing tests: a request authenticated via an OAuth token whose grant recorded actor `"Alice Example"` produces `changed` events with `"by": "Alice Example"` regardless of any `X-Actor` header sent; static-key requests are unaffected
- [ ] 1.10 Implement actor resolution so OAuth-token requests use the grant's recorded actor instead of `X-Actor`, so 1.9 passes
- [ ] 1.11 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): accept scoped OAuth tokens on the REST API and WebSocket`

## 2. OIDC relying-party core (PR 2)

- [x] 2.1 Write failing tests in `server/test/src/config_test.dart`: all three of `--oidc-issuer`/`ROBOT_NOTES_OIDC_ISSUER`, `--oidc-client-id`/`ROBOT_NOTES_OIDC_CLIENT_ID`, `--oidc-client-secret`/`ROBOT_NOTES_OIDC_CLIENT_SECRET` set resolves into `Config.oidc` (issuer, clientId, clientSecret); none set yields `Config.oidc == null`; exactly one or two set throws `ConfigError` naming the missing setting(s); CLI flag beats env var per setting
- [x] 2.2 Implement `Config.oidc` so 2.1 passes
- [x] 2.3 Write failing tests in `server/test/src/oidc/discovery_test.dart`: fetching a well-formed `/.well-known/openid-configuration` extracts `authorization_endpoint`, `token_endpoint`, `jwks_uri`; a missing field or unreachable issuer throws a startup error naming the issuer
- [x] 2.4 Implement `lib/src/oidc/discovery.dart` so 2.3 passes; wire a fetch-at-startup call into `AppDeps.bootstrap` (only when `Config.oidc != null`), failing startup non-zero on error
- [x] 2.5 Write failing tests in `server/test/src/oidc/jwks_test.dart`: a JWKS document's keys are indexed by `kid`; verifying a token whose `kid` is absent from the cache triggers exactly one refetch before failing or succeeding; a token using `alg=none` or any algorithm outside `RS256`/`ES256` is rejected before signature verification is attempted
- [x] 2.6 Implement `lib/src/oidc/jwks.dart` (fetch, cache, refetch-on-miss, algorithm allowlist) so 2.5 passes
- [x] 2.7 Write failing tests in `server/test/src/oidc/id_token_test.dart`: a validly signed token with correct `iss`/`aud`/unexpired `exp`/matching `nonce` verifies and yields its claims; wrong `iss`, wrong `aud`, expired `exp`, mismatched `nonce`, and a bad signature are each rejected with a distinct, testable reason — tested with real RS256 and ES256 signatures generated via `package:pointycastle` in `_id_token_test_helpers.dart`, not mocked crypto
- [x] 2.8 Implement `lib/src/oidc/id_token.dart` (JWS signature check via `jwks.dart` + claim validation) so 2.7 passes — signature verification (RS256 and ES256) uses `package:pointycastle`, added as a new server dependency per design.md decision 3 (revised from the original hand-roll-everything plan after ECDSA proved unsafe to hand-roll); structure parsing and claim checks remain hand-rolled
- [x] 2.9 Write failing tests in `server/test/src/oidc/pending_login_test.dart`: starting a login persists a PKCE verifier/challenge, `state`, and `nonce` bound to a pending `/oauth/authorize` consent request, expiring after 10 minutes; looking up by `state` after expiry fails
- [x] 2.10 Implement `lib/src/oidc/pending_login_store.dart` so 2.9 passes — process-local, non-persisted (matches `ConsentThrottle`'s precedent for ephemeral OAuth-adjacent state)
- [x] 2.11 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): add OIDC discovery, JWKS verification, and pending-login store`

## 3. OIDC login and callback routes (PR 3)

- [ ] 3.1 Write failing route tests in `server/test/routes/oauth/oidc/login_test.dart`: starting login from a pending consent request redirects to the provider's `authorization_endpoint` with `response_type=code`, the configured `client_id`, `scope` containing `openid`, `code_challenge_method=S256`, a `state`, and a `nonce`; an unknown/expired consent request 400s without redirecting
- [ ] 3.2 Implement `routes/oauth/oidc/login.dart` so 3.1 passes
- [ ] 3.3 Write failing route tests in `server/test/routes/oauth/oidc/callback_test.dart`: a `state` matching no pending login is rejected without completing consent; a matching `state` whose code-exchange and ID-token verification succeed mints an authorization code for the original consent request, using the ID token's `name` (falling back to `email`, then `sub`) as actor, and redirects to the original client's `redirect_uri` with `code`/`iss`/`state`; a verification failure (bad signature, wrong `iss`/`aud`, expired, nonce mismatch) abandons the pending request and renders an error page without minting a code
- [ ] 3.4 Implement `routes/oauth/oidc/callback.dart` so 3.3 passes, reusing the existing code-minting path from `routes/oauth/authorize.dart` (extract a shared `completeConsent(...)` helper if it doesn't already exist so both the `api_key` POST and this callback mint codes identically)
- [ ] 3.5 Write failing tests in `server/test/src/oauth/metadata_test.dart`: `GET /.well-known/oauth-authorization-server` includes `"robotnotes_oidc_login_supported": true` when OIDC is configured and omits the field otherwise
- [ ] 3.6 Implement the metadata addition in `lib/src/oauth/metadata.dart` so 3.5 passes
- [ ] 3.7 Write failing tests in `server/test/src/oauth/consent_page_test.dart`: when OIDC is configured, the rendered consent page contains a sign-in link/button that starts the OIDC login flow and does NOT contain an `api_key` password input; when not configured, the page is unchanged from today
- [ ] 3.8 Implement the conditional branch in `lib/src/oauth/consent_page.dart` so 3.7 passes
- [ ] 3.9 Add the two new routes to `server/test/integration/_test_app.dart`; write `server/test/integration/oidc_login_flow_test.dart` running the full path against a stub OIDC provider (a tiny in-test HTTP server serving discovery, authorize, token, and a signed ID token): register a client, start `/oauth/authorize`, follow the sign-in link, complete the stub provider's login, land back on the callback, exchange the resulting code at `/oauth/token`, and assert the token works at `/notes` with the actor derived from the stub's ID token
- [ ] 3.10 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): add OIDC login and callback routes, wire into consent`

## 4. Flutter app: sign-in as an alternative to pasting a key (PR 4)

Desktop and web only, per proposal.md - Non-goals.

- [ ] 4.1 Write failing tests in `app/test/src/setup/server_capabilities_test.dart`: fetching a server's `/.well-known/oauth-authorization-server` and reading `robotnotes_oidc_login_supported`; a network failure or missing field yields "not supported" rather than throwing
- [ ] 4.2 Implement `lib/src/setup/server_capabilities.dart` so 4.1 passes
- [ ] 4.3 Write failing tests in `app/test/src/auth/oauth_client_test.dart`: registers itself via `POST /oauth/register` once and caches the returned `client_id` (and secret, if confidential) in secure storage; builds a correct PKCE-authorize URL with `resource=<base>` and `scope=notes:read notes:write`
- [ ] 4.4 Implement `lib/src/auth/oauth_client.dart` (registration + authorize-URL builder) so 4.3 passes
- [ ] 4.5 Write failing tests in `app/test/src/auth/loopback_redirect_test.dart` (desktop): binds an ephemeral loopback `HttpServer`, returns its port for the `redirect_uri`, and resolves with the `code`/`state` query parameters from the first request it receives, then shuts the listener down
- [ ] 4.6 Implement `lib/src/auth/loopback_redirect.dart` so 4.5 passes
- [ ] 4.7 Write failing tests in `app/test/src/auth/oauth_client_test.dart` (web variant): on web, the redirect URI is same-origin and the callback page hands the `code`/`state` back to the running app instance without a full reload losing app state
- [ ] 4.8 Implement the web callback handling so 4.7 passes
- [ ] 4.9 Write failing tests in `app/test/src/config/config_store_test.dart`: an OAuth session (access token, refresh token, actor name) persists and loads via the same secure-storage mechanism as the API key; neither token appears in any produced log line; loading refreshes an expired access token automatically using the stored refresh token
- [ ] 4.10 Extend `lib/src/config/config_store.dart` so 4.9 passes
- [ ] 4.11 Write failing widget tests in `app/test/src/setup/setup_screen_test.dart`: on desktop/web when the entered server supports OIDC, a "Sign in" option appears alongside manual key entry; on mobile, or when unsupported, only manual entry appears; completing sign-in proceeds to the notes list using the signed-in display name
- [ ] 4.12 Implement the "Sign in" option and flow wiring in `lib/src/setup/setup_screen.dart` so 4.11 passes, keeping manual key entry as the always-available fallback
- [ ] 4.13 Run `flutter test` in `app/`, `dart format .`, `flutter analyze`; commit as `feat(app): add OIDC sign-in as an alternative to pasting the API key`

## 5. Docs and definition of done (PR 5)

- [ ] 5.1 Update `README.md`: document `--oidc-issuer`/`--oidc-client-id`/`--oidc-client-secret` and their env vars next to `--api-key`, explain the coexistence model (static key for agents, OIDC for humans), and note the desktop/web-only scope for the app's sign-in option
- [ ] 5.2 Update `server/API.md` (or wherever the consent flow is documented) to describe the OIDC branch of the consent page
- [ ] 5.3 Every scenario in `specs/oidc-login` and the `auth`, `oauth-authorization`, and `flutter-client` deltas maps to at least one test that failed before and passes after its implementation task
- [ ] 5.4 `dart format --set-exit-if-changed .` and `dart analyze` are clean; `make test` passes on the top of the stack
- [ ] 5.5 `openspec validate add-oidc-login --strict` passes
- [ ] 5.6 Manual smoke run against a real OIDC provider (e.g. a local Keycloak/Authentik container or a free-tier test tenant): configure the three env vars, open the app's setup screen, sign in, confirm notes load; separately complete an MCP consent via the sign-in link instead of pasting the key
- [ ] 5.7 Five PRs opened as a stack in dependency order, each under 500 changed lines, each green on CI
