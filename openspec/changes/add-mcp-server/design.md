## Context

See proposal.md for motivation. Constraints that shape the design:

- The server is Dart Frog on top of shelf. Handlers see a shelf `Request`, never a raw `dart:io` `HttpRequest`.
- Auth today is one static bearer key checked by `bearerAuth` in `routes/_middleware.dart`, with a hard-coded exemption list. `staticWebMiddleware` short-circuits everything that is not an API prefix when the web bundle is served.
- Notes are written through `NoteWriteService` (storage + meta index + FTS + broadcast). Locks live in `LockManager`. Search in `SearchIndex`. All are provided through the request context.
- `InviteStore` is the existing pattern for small file-backed records: one JSON file per record, tmp+fsync+rename, per-key mutex, injectable `Clock` and `Random`.
- Invite URLs are built from request scheme + `Host`; there is no notion of a public base URL yet.
- The MCP authorization spec (2025-06-18) requires RFC 9728 protected-resource metadata, RFC 8414 AS metadata, PKCE S256, RFC 8707 `resource`, audience validation, and `WWW-Authenticate` on 401. DCR (RFC 7591) is how hosted agents obtain a client id with no operator interaction.

## Goals / Non-Goals

**Goals:**

- Zero-config connection from a hosted or local MCP client: paste `<base>/mcp`, approve in the browser with the API key, done.
- Keep the static key working for invite-onboarded agents at `/mcp` so the two onboarding paths coexist.
- Every requirement in the specs has a test; no new runtime dependency beyond `crypto`.
- Each PR under 500 changed lines; the work ships as a stack.

**Non-Goals:**

- SSE streaming, sessions, resumability, server-initiated requests.
- Anything beyond tools (resources, prompts, completions).
- Multi-user identity. The consent page proves "I hold the workspace key", nothing finer.

## Decisions

### D1: Hand-rolled JSON-RPC dispatch instead of an MCP SDK

**Choice:** Implement the MCP method surface (`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`) as a small pure-Dart dispatcher (`lib/src/mcp/json_rpc.dart` + `lib/src/mcp/mcp_handler.dart`) invoked from a Dart Frog route.

**Alternatives considered:**

- `package:mcp_dart` ships `StreamableHTTPServerTransport`, but it consumes `dart:io` `HttpRequest` directly. Dart Frog never exposes that object, so integration would mean a second listener or a custom per-request `Transport` shim around internals we do not control.
- `package:dart_mcp` (dart-lang) has no HTTP server transport at all.

Five methods and seven tools are a few hundred lines; owning them keeps the server testable with plain `Request` objects and keeps the dependency graph unchanged. The protocol details we must get right (error codes, `id` echo, version negotiation, 202 for notifications) are all captured as spec scenarios.

### D2: Stateless transport, JSON responses only

**Choice:** No `Mcp-Session-Id`, no SSE, `GET /mcp` is 405. Every POST is independent; `initialize` is answered but nothing is remembered.

**Why:** The tools are request/response. Statelessness means restarts and horizontal scaling never break a client, and there is no session store to leak or expire. The Streamable HTTP spec explicitly allows this shape. If streaming is needed later, SSE can be added behind the same path without changing the auth model.

### D3: The server is its own authorization server; consent = API key + actor name

**Choice:** Colocate the AS with the resource server. `issuer` is `<base>`, endpoints live under `/oauth/*`. The consent page asks for the workspace API key (proof of ownership, since the deployment is single-tenant) and the display name the agent should write under.

**Alternatives considered:**

- Delegating to an external IdP: adds operator configuration for a product whose pitch is "one binary, one folder, one key" and does not remove the need for DCR.
- Invite-token consent (paste an invite URL instead of the key): invites are single-use and burn on fetch; reusing them as a login credential would muddle two lifecycles. Can be layered later as an alternative consent proof.

The actor captured at consent becomes the `X-Actor`-equivalent for every call made with that grant, so agents cannot impersonate each other by header.

### D4: Opaque random tokens, hashed at rest, file-backed under `<data-dir>/oauth/`

**Choice:** `client_id`, codes, access tokens, refresh tokens, and client secrets are `Random.secure()` bytes, base64url without padding (16 bytes for client ids, 32 bytes for secrets, codes, and tokens). Codes and tokens are stored under their SHA-256 hash: `oauth/clients/<client_id>.json`, `oauth/codes/<sha256>.json`, `oauth/tokens/<sha256>.json`. Each token record carries `grant_id`, `client_id`, `actor`, `scope`, `resource`, `kind` (`access`/`refresh`), `expires_at`, `revoked_at`, and for refresh tokens `rotated_at`. Every record from one consent shares a `grant_id` so reuse detection and revocation can cascade with a directory scan.

**Alternatives considered:**

- JWT access tokens: self-contained but demand key management and make revocation a blocklist anyway. Opaque + lookup is simpler and the store is local disk.
- SQLite table in `search.db`: that database is documented as a derived, rebuildable cache; credentials must not live in something the server may delete and rebuild.

Stores follow `InviteStore` exactly (tmp+fsync+rename, per-key mutex, injectable `Clock`/`Random`), split as `ClientStore`, `CodeStore`, `TokenStore` in `lib/src/oauth/`.

### D5: One `PublicUrl` resolver shared by OAuth and invites

**Choice:** `Config.publicUrl` (from `--public-url` / `ROBOT_NOTES_PUBLIC_URL`, validated at startup) plus a `publicBaseUrl(RequestContext)` helper that falls back to `X-Forwarded-Proto` / request scheme + `Host`. The invite route switches to the helper so both features agree on `<base>`. The canonical resource is `<base>/mcp` and is what tokens are bound to and what the `resource` parameter is checked against.

### D6: Auth layering for the new paths

**Choice:** `bearerAuth` gains exemptions for `/.well-known/oauth-*`, `/oauth/*`, and `/mcp`. `/mcp` gets its own middleware (`routes/mcp/_middleware.dart`) that accepts either the static key or a `TokenStore` access token, sets `context.read<McpPrincipal>()` (actor + scope set), and emits the 401 with `WWW-Authenticate`. The OAuth token/revoke routes authenticate clients themselves per registered method. `staticWebMiddleware` passthrough prefixes gain `/mcp`, `/oauth`, `/.well-known`.

**Why a separate principal type:** the existing `Actor` is header-derived; the MCP principal also carries scopes and its source. Tools read the principal, not `Actor`.

### D7: `.well-known` documents served from middleware, not route files

**Choice:** A `wellKnownMiddleware` placed before `bearerAuth` answers the three discovery paths. Dart Frog derives routes from directory names and a leading-dot directory is an unnecessary gamble; a middleware is explicit and trivially unit-tested. The metadata JSON is built by a pure function of `<base>` so the OAuth routes and the tests share it.

### D8: Tool layer sits on the existing services

**Choice:** `lib/src/mcp/tools.dart` defines a `McpTool` (name, description, input schema, handler) registry. Handlers call `MetaIndex`, `Storage`, `NoteWriteService`, `LockManager`, and `SearchIndex` the same way the HTTP routes do, and translate `NoteNotFoundException`, `VersionConflictException`, lock conflicts, and `InvalidSearchQueryException` into `isError` tool results with `structuredContent.error` codes taken from the shared `ErrorCode` enum. `append_to_note` loops: read, concatenate, `update` at the read version, retry on conflict up to 3 times. Success results always carry `content[0].text` (JSON string) and `structuredContent` (object).

Input validation is done against the declared schema by hand (type and range checks) so `-32602` is raised for shape errors and `validation_failed` tool errors for semantic ones, matching the spec.

### D9: Consent page is server-rendered HTML with no scripts

**Choice:** A single template function renders the form; every echoed value is HTML-escaped; the response sets `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'` and `X-Frame-Options: DENY`. Parameters round-trip as hidden inputs, and the POST re-validates everything from scratch, so the GET step holds no server state.

### D10: PR stack

1. `feat(server): public base URL config and OAuth discovery documents` — `Config.publicUrl`, `PublicUrl` helper, invite route reuse, well-known middleware, auth exemptions, static passthrough, shared route constants.
2. `feat(server): OAuth client, code, and token stores` — records, stores, PKCE helper, startup purge; pure library plus unit tests.
3. `feat(server): OAuth registration, consent, token, and revocation routes` — the four routes, client authentication helper, form parsing, consent template; route tests plus an end-to-end flow test.
4. `feat(server): MCP JSON-RPC core and note tools` — dispatcher, tool registry, tool handlers; unit tests with fakes and real services on a temp dir.
5. `feat(server): serve MCP at /mcp with OAuth and static-key auth` — route, principal middleware, origin/version checks, integration tests through the test app, onboarding bundle line, README and API.md.

Stack order is the dependency order; 2 and 4 touch disjoint files and can be built concurrently off 1.

## Risks / Trade-offs

- [Consent form is a new brute-force surface for the API key] → Same exposure class as the existing bearer check; constant-time compare; documented as follow-up to add lockout. Operators are told to run behind HTTPS.
- [Trusting `Host` / `X-Forwarded-Proto` when no public URL is set] → Documented; `--public-url` is recommended for any proxied deployment and is what the Docker docs show.
- [Directory scans for grant-family revocation are O(tokens)] → Token counts are tiny (one grant per connected agent); startup purge keeps the directory bounded.
- [Hosted MCP clients may send `Origin`] → Origin check accepts the public origin, so clients that echo the server origin still work; foreign origins are exactly what should be refused.
- [Hand-rolled protocol may drift from future MCP revisions] → The supported version list is a single constant and the surface is tiny; version negotiation is spec-tested.
- [Static key at `/mcp` bypasses scopes] → Intended: the key is the root credential everywhere else too.

## Migration Plan

Additive. Deploy the new image; `<data-dir>/oauth/` is created on first registration. Rollback is redeploying the previous image; leftover `oauth/` files are inert. Operators behind a proxy should set `ROBOT_NOTES_PUBLIC_URL` before pointing agents at the server so the `issuer` is stable.
