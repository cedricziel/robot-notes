## 1. Public base URL and OAuth discovery (PR 1)

- [x] 1.1 Write failing tests in `server/test/src/config_test.dart`: `--public-url` and `ROBOT_NOTES_PUBLIC_URL` resolve into `Config.publicUrl`; values with a path, query, fragment, missing scheme, or non-http(s) scheme throw `ConfigError` naming both mechanisms; unset yields `null`
- [x] 1.2 Implement `Config.publicUrl` (flag, env, validation, usage line) so 1.1 passes; run `cd server && dart test test/src/config_test.dart`
- [x] 1.3 Write failing tests in `server/test/src/public_url_test.dart`: resolver returns the configured URL when set; otherwise `X-Forwarded-Proto` + `Host`; otherwise request scheme + `Host`; result never ends with `/`
- [x] 1.4 Implement `lib/src/public_url.dart` (`publicBaseUrl(RequestContext)` and `mcpResourceUrl(base)`) so 1.3 passes
- [x] 1.5 Switch `routes/invites/index.dart` to the resolver; verify `dart test test/routes/invites` still passes and add one case where a configured public URL changes the invite URL host
- [x] 1.6 Add `Routes.mcp`, `Routes.oauthRegister`, `Routes.oauthAuthorize`, `Routes.oauthToken`, `Routes.oauthRevoke`, `Routes.wellKnownProtectedResource`, `Routes.wellKnownAuthorizationServer` to `shared/lib/src/routes.dart` with a failing-then-passing test in `shared/test/routes_test.dart`
- [x] 1.7 Write failing tests in `server/test/src/well_known_middleware_test.dart` covering the three discovery paths (fields per the `oauth-authorization` spec), 200 without auth, 404 for other `/.well-known/` paths, and pass-through for unrelated paths
- [x] 1.8 Implement `lib/src/oauth/metadata.dart` (pure builders for both documents) and `lib/src/well_known_middleware.dart`; wire it into `routes/_middleware.dart` and `test/integration/_test_app.dart` so 1.7 passes
- [x] 1.9 Write failing tests in `server/test/src/auth_middleware_test.dart`: `/oauth/register|authorize|token|revoke`, `/.well-known/oauth-*`, and `/mcp` are exempt from the static key; `/keys`, `/rotate`, `/auth/rotate` still 404 through the app; a made-up `/oauthx` is still 401
- [x] 1.10 Extend `bearerAuth` exemptions so 1.9 passes
- [x] 1.11 Write failing test in `server/test/src/static_web_middleware_test.dart`: with a web dir, `/mcp`, `/oauth/token`, `/.well-known/oauth-authorization-server` pass through; then add the prefixes so it passes
- [x] 1.12 Run `dart format .`, `dart analyze`, `cd server && dart test`, `cd shared && dart test`; commit as `feat(server): add public base URL and OAuth discovery documents`

## 2. OAuth stores and PKCE (PR 2)

- [x] 2.1 Write failing tests in `server/test/src/oauth/pkce_test.dart`: `S256(verifier)` matches the RFC 7636 appendix B vector; `verify(challenge, verifier)` is constant-time-compared and rejects mismatches and non-base64url input
- [x] 2.2 Implement `lib/src/oauth/pkce.dart` so 2.1 passes; add `crypto` as a direct dependency in `server/pubspec.yaml` and run `dart pub get`
- [x] 2.3 Write failing tests in `server/test/src/oauth/client_store_test.dart`: `register` persists a JSON file keyed by `client_id`, secrets are stored hashed (file does not contain the raw secret), `get` round-trips, `verifySecret` accepts the right secret and rejects a wrong one, malformed files are skipped with a warning
- [x] 2.4 Implement `lib/src/oauth/oauth_records.dart` (`OAuthClient`, `AuthorizationCode`, `OAuthToken` with `fromJson`/`toJson`) and `lib/src/oauth/client_store.dart` so 2.3 passes
- [x] 2.5 Write failing tests in `server/test/src/oauth/code_store_test.dart`: `mint` returns a raw code and persists only its hash; `consume` returns the record once and throws on the second call; expired codes are rejected; the record keeps client id, redirect URI, challenge, scope, resource, actor, grant id
- [x] 2.6 Implement `lib/src/oauth/code_store.dart` so 2.5 passes (10-minute TTL constant, per-hash mutex)
- [x] 2.7 Write failing tests in `server/test/src/oauth/token_store_test.dart`: `issue` returns raw access and refresh tokens and persists hashed records with 1h/30d expiries; `lookupAccess` rejects refresh tokens, expired, and revoked records; `rotateRefresh` returns new tokens, marks the old one rotated, and a second rotation of the same token throws a reuse error; `revokeGrant` marks every record of the grant; `revokeToken` on an access token revokes only itself
- [x] 2.8 Implement `lib/src/oauth/token_store.dart` so 2.7 passes
- [x] 2.9 Write failing test in `server/test/src/oauth/purge_test.dart`: `purgeExpired(now)` deletes expired code and token files, keeps unexpired ones, returns the count; then implement it on the stores
- [x] 2.10 Write failing test in `server/test/src/app_deps_test.dart`: `AppDeps.bootstrap` constructs the three stores under `<dataDir>/oauth/` and runs the purge; then wire them into `AppDeps` and `AppDeps.close`
- [x] 2.11 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): add OAuth client, code, and token stores`

## 3. OAuth registration, consent, token, and revocation routes (PR 3)

- [x] 3.1 Write failing tests in `server/test/src/oauth/form_body_test.dart` for a form-urlencoded parser (repeated keys, plus-as-space, percent decoding, wrong content type rejected); implement `lib/src/oauth/form_body.dart`
- [x] 3.2 Write failing tests in `server/test/src/oauth/client_auth_test.dart`: `authenticateClient` resolves `none` (body `client_id`), `client_secret_post`, and `client_secret_basic`, and fails with `invalid_client` on wrong secret or method mismatch; implement `lib/src/oauth/client_auth.dart`
- [x] 3.3 Write failing route tests in `server/test/routes/oauth/register_test.dart` for every scenario of "Dynamic Client Registration mints public or confidential clients" (public, confidential, localhost redirect, plain http rejected, missing redirect URIs, unsupported method, `Cache-Control: no-store`, 405 on GET)
- [x] 3.4 Implement `routes/oauth/register.dart` so 3.3 passes
- [x] 3.5 Write failing tests in `server/test/src/oauth/consent_page_test.dart`: the template escapes `<script>` in client name and state, renders scopes, the `api_key` password input, the `actor` input prefilled, every hidden parameter, and the error banner when given an error
- [x] 3.6 Implement `lib/src/oauth/consent_page.dart` so 3.5 passes
- [x] 3.7 Write failing route tests in `server/test/routes/oauth/authorize_test.dart` for the GET scenarios (consent renders, unregistered redirect does not redirect, missing PKCE redirects with `invalid_request` and `state`, wrong resource redirects with `invalid_target`, unknown scope redirects with `invalid_scope`, default scope) and the POST scenarios (correct key redirects with `code`, `iss`, `state`; wrong key re-renders without minting; empty actor falls back to client name; CSP and `X-Frame-Options` headers present)
- [x] 3.8 Implement `routes/oauth/authorize.dart` (shared validator for GET and POST, constant-time key check) so 3.7 passes
- [x] 3.9 Write failing route tests in `server/test/routes/oauth/token_test.dart` for the code-exchange scenarios (success shape and `no-store`, wrong verifier, code reuse revokes, expired code, wrong redirect URI, wrong client, confidential wrong secret, unsupported grant type, missing params) and the refresh scenarios (rotation, reuse revokes family, scope cannot widen, expired refresh)
- [x] 3.10 Implement `routes/oauth/token.dart` so 3.9 passes
- [x] 3.11 Write failing route tests in `server/test/routes/oauth/revoke_test.dart` (refresh revocation cascades, access revocation is local, unknown token 200, bad client 401); implement `routes/oauth/revoke.dart`
- [x] 3.12 Add the four routes to `test/integration/_test_app.dart`; write `server/test/integration/oauth_flow_test.dart` running register, authorize GET, consent POST, token exchange, and refresh end to end over HTTP with a real PKCE pair
- [x] 3.13 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): add OAuth registration, consent, token, and revocation routes`

## 4. MCP JSON-RPC core and note tools (PR 4)

- [x] 4.1 Write failing tests in `server/test/src/mcp/json_rpc_test.dart`: parse a request, a notification, a client response, reject arrays, reject missing `jsonrpc`, reject non-object; build result and error envelopes that echo `id`; error code constants -32700/-32600/-32601/-32602
- [x] 4.2 Implement `lib/src/mcp/json_rpc.dart` so 4.1 passes
- [x] 4.3 Write failing tests in `server/test/src/mcp/tool_results_test.dart`: `ok(payload)` yields one text item with the JSON string plus identical `structuredContent`; `fail(code, details)` sets `isError`, text starting with the code, and `structuredContent.error`
- [x] 4.4 Implement `lib/src/mcp/tool_results.dart` and `lib/src/mcp/principal.dart` (`McpPrincipal` with actor, scopes, `isStaticKey`) so 4.3 passes
- [x] 4.5 Write failing tests in `server/test/src/mcp/tools_test.dart` (real `AppDeps` on a temp dir): `list_notes` pagination and clamping, `get_note` including `lock` when held and `not_found`, `search_notes` hit with `<mark>` and `validation_failed` on blank or invalid FTS query
- [x] 4.6 Implement `lib/src/mcp/tools.dart` registry with schemas plus the three read tools so 4.5 passes
- [x] 4.7 Write failing tests for the write tools: `create_note` success and empty title, `update_note` success, stale version with `current_version`/`current_content`, neither title nor content, `locked` with holder, `delete_note` success and `locked`, each write broadcasting `changed` with the principal's actor
- [x] 4.8 Implement `create_note`, `update_note`, `delete_note` so 4.7 passes
- [x] 4.9 Write failing tests for `append_to_note`: newline separation, empty existing content, existing trailing newline not doubled, empty text rejected, `locked`, and two concurrent appends both landing
- [x] 4.10 Implement `append_to_note` with the retry loop so 4.9 passes
- [x] 4.11 Write failing tests for scope gating: read-only principal calling a write tool gets `insufficient_scope`; write-only principal calling a read tool gets `insufficient_scope`; static-key principal passes both
- [x] 4.12 Implement scope checks in the registry dispatch so 4.11 passes
- [x] 4.13 Write failing tests in `server/test/src/mcp/mcp_handler_test.dart`: `initialize` result shape and version negotiation (echo supported, fall back to 2025-06-18), `ping` returns `{}`, `tools/list` returns the seven tools with `required` arrays, `tools/call` routes to the registry, unknown tool is -32602, unknown method is -32601, notifications yield no response
- [x] 4.14 Implement `lib/src/mcp/mcp_handler.dart` (pure: message in, optional message out) so 4.13 passes
- [x] 4.15 Run `dart format .`, `dart analyze`, `cd server && dart test`; commit as `feat(server): add MCP JSON-RPC core and note tools`

## 5. Serve MCP at /mcp (PR 5)

- [x] 5.1 Write failing tests in `server/test/src/mcp/mcp_auth_middleware_test.dart`: missing header 401 with `WWW-Authenticate` carrying `resource_metadata` and no `error`; bad token 401 with `error="invalid_token"`; static key yields a principal with `X-Actor` and both scopes; valid access token yields the grant's actor and scopes and ignores `X-Actor`; refresh token rejected; token for another resource rejected; query-string token ignored
- [x] 5.2 Implement `lib/src/mcp/mcp_auth_middleware.dart` and `routes/mcp/_middleware.dart` so 5.1 passes
- [x] 5.3 Write failing route tests in `server/test/routes/mcp/index_test.dart`: GET and DELETE 405 with `Allow: POST`; `Mcp-Session-Id` ignored and never emitted; foreign `Origin` 403 before body parsing, own origin and loopback accepted, absent origin accepted; unsupported `MCP-Protocol-Version` 400; malformed JSON 400 with -32700; batch 400 with -32600; notification 202 empty; request 200 `application/json`
- [x] 5.4 Implement `routes/mcp/index.dart` so 5.3 passes
- [x] 5.5 Add `/mcp` and its middleware to `test/integration/_test_app.dart`; write `server/test/integration/mcp_flow_test.dart`: register, consent, token, then `initialize`, `tools/list`, `create_note`, `append_to_note`, `search_notes`, `delete_note` over HTTP, asserting the `changed` events on a WebSocket subscriber carry the consented actor
- [x] 5.6 Extend `mcp_flow_test.dart`: expired access token rejected (injected clock), refresh then success, revoke then 401, and token accepted after closing and re-bootstrapping `AppDeps` on the same data dir
- [x] 5.7 Write failing test in `server/test/routes/invites/[token]/onboarding.txt_test.dart` for the `ROBOT_NOTES_MCP_URL` line and `/mcp` mention; update `lib/src/onboarding_bundle.dart`
- [x] 5.8 Document in `README.md` and `server/API.md`: connecting an MCP client (URL, OAuth consent flow, static-key header alternative), `--public-url`, the tool catalog, and the security notes on HTTPS and the consent form
- [x] 5.9 Run `dart format .`, `dart analyze`, `make test`; commit as `feat(server): serve MCP at /mcp with OAuth and static-key auth`

## 6. Definition of Done

- [x] 6.1 Every scenario in `specs/mcp-server`, `specs/oauth-authorization`, and the `auth` and `agent-onboarding` deltas maps to at least one test that fails before and passes after its implementation task
- [x] 6.2 `dart format --set-exit-if-changed .` and `dart analyze` are clean; `make test` passes on the top of the stack
- [x] 6.3 `npx @fission-ai/openspec validate add-mcp-server --strict` passes
- [x] 6.4 A manual smoke run: `make run-server`, register a client with `curl`, complete consent in a browser, call `tools/list` with the issued token
- [x] 6.5 Five PRs opened as a stack in dependency order, each under 500 changed lines, each green on CI
