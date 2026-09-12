## Context

The server already hand-rolls a full OAuth 2.1 authorization server
(`server/lib/src/oauth/`: DCR, PKCE, code/token stores, consent page) whose
only job today is letting MCP clients get `/mcp`-scoped tokens without the
static key. Its consent step proves the resource owner's identity by
re-checking the static key (`consent_page.dart`, `routes/oauth/authorize.dart`).
`bearerAuth()` (`server/lib/src/auth_middleware.dart`) currently accepts
exactly one credential — the static key — everywhere except `/mcp`, which
separately also accepts an `/mcp`-scoped OAuth token
(`server/lib/src/mcp/mcp_auth_middleware.dart`). There is no JWT/JWKS
handling anywhere in the codebase and no OAuth/OIDC client library in any
`pubspec.yaml`. See proposal.md - Why / What Changes for motivation and scope.

## Goals / Non-Goals

**Goals:**

- Let a human prove their identity via an external OIDC provider instead of
  pasting the static key, on both surfaces named in the proposal.
- Reuse the existing OAuth 2.1 AS end-to-end (DCR, PKCE, code/token issuance,
  refresh) rather than building a second grant/token system.
- Keep OIDC entirely opt-in: absent config, zero behavior change.

**Non-Goals:**

- Restating proposal.md's Non-goals (mobile, multi-provider, claims-based
  authorization, replacing the static key) — see there.
- Building a general-purpose OIDC library; this only needs to support the
  authorization-code flow with PKCE against one issuer.

## Decisions

### 1. OIDC is a login _event_, not an ongoing session mechanism

The server only talks to the external IdP at login time: it redirects there,
receives a code, exchanges it, and verifies the returned ID token. It never
stores or refreshes the IdP's own tokens. Once verified, the OIDC identity is
just the fact that lets the _existing_ OAuth AS finish issuing its own
authorization code/access/refresh tokens, exactly as if the consent form's
key check had passed. All session lifecycle (expiry, refresh, revocation)
after that point is the already-built and already-tested robot-notes OAuth
token machinery — nothing new to design there.

Alternative considered: treat the IdP's tokens as the long-lived credential
(store/refresh them, forward the ID token as a bearer credential). Rejected —
it would mean building a second, parallel session/refresh model alongside
the one that already exists, doubling the surface for no benefit given
exactly one deployment-wide identity provider and no per-user permission
model.

### 2. `bearerAuth()` accepts OAuth tokens by scope, not by route allowlist

Today `/mcp` has its own bespoke middleware that additionally accepts OAuth
tokens; every other route accepts only the static key. Instead of adding a
second bespoke middleware for REST/WS, `bearerAuth()` itself learns to
recognize a server-issued OAuth access token (as it already can be asked to
validate for `/mcp`) and authorize the request if the token's scopes cover
the operation (`notes:read` for GET-shaped requests, `notes:write` for
mutations), independent of which route it landed on. This keeps one
authentication code path instead of two, and means a future resource (not
just `/mcp` and the REST API) gets OAuth-token support for free.

Alternative considered: keep `/mcp`'s bespoke middleware pattern and add a
near-identical one for REST/WS. Rejected — duplicates logic that's already
subtle (constant-time comparison, scope checks, expiry) for no upside.

### 3. Hand-roll ID-token/JWKS verification; no new server dependency

The server verifies exactly one thing cryptographically: an ID token's
signature (fetched via the issuer's `/.well-known/openid-configuration` →
`jwks_uri`, standard RS256/ES256 JWS), plus `iss`/`aud`/`exp`/`nonce` claim
checks. This is a small, well-understood surface, and the existing OAuth AS
already hand-rolls comparable primitives (`oauth_crypto.dart`, PKCE
challenge/verifier). Adding a general OIDC client package would pull in far
more surface (userinfo, session management, provider quirks) than this
change needs.

Alternative considered: use a package such as `openid_client`. Rejected for
now — it would be the first third-party OAuth/OIDC dependency in a codebase
that has deliberately hand-rolled this category so far, for a verification
step (JWS signature + claim checks) that's straightforward to implement and
test directly against RFC 7517/7519.

### 4. The app's own OAuth client is minimal and desktop/web only

The Flutter app registers itself once via DCR and runs the standard
authorization-code+PKCE flow against its own server. On web, the redirect is
same-origin (the server serves the Flutter web bundle), so the callback page
just needs to hand the resulting code back to the running app instance. On
desktop, the app opens the system browser and listens on an ephemeral
loopback port (`http://127.0.0.1:<port>/callback`) for the redirect — a
already-legal `redirect_uri` under the existing DCR validation. No new
Flutter dependency is needed for either case (a bound `HttpServer` covers the
loopback listener; `url_launcher`, already a dependency, opens the system
browser).

### 5. `X-Actor` for OIDC sessions comes from the ID token, not the header

When a request authenticates via an OIDC-derived OAuth token, the actor
identity used for locks/presence/`changed` events is the token's associated
`name` (falling back to `email`) claim, captured at token-issuance time and
stored alongside the token record — not read from a client-supplied
`X-Actor` header, which remains untrusted free text for static-key requests.

## Risks / Trade-offs

- [The external IdP becomes a hard runtime dependency for human login] →
  Mitigated by keeping the static key path fully independent — an IdP outage
  blocks new human logins, not agents, scripts, or already-issued sessions.
- [Loopback-redirect desktop login can be blocked by strict OS firewalls or
  fail if the ephemeral port collides] → Mitigate by trying a small fixed
  range and surfacing a clear error with the manual-key fallback still
  available in the same screen.
- [Hand-rolled JWT verification is a common source of auth bugs (alg
  confusion, missing `aud` check, accepting `none`)] → Mitigate with an
  explicit allowlist of accepted signing algorithms (RS256, ES256 only, no
  `none`), mandatory `iss`/`aud`/`exp`/`nonce` checks, and a dedicated test
  suite covering each rejection case per RFC 7519 §4.1 / OIDC Core §3.1.3.7.
- [Widening `bearerAuth()` to accept scoped OAuth tokens on REST/WS changes a
  documented security invariant in `openspec/specs/auth/spec.md`] →
  Mitigated by making it strictly additive (the static key keeps working
  unchanged) and covering the new acceptance path with the same scrutiny as
  the existing one (scope check, expiry, revocation) in the `auth` spec
  delta.

## Migration Plan

Purely additive and opt-in: deploying this change with no OIDC env vars set
changes nothing observable. An operator who wants OIDC login sets the three
new env vars (or CLI flags) and restarts, matching the existing
`ROBOT_NOTES_API_KEY` operational pattern. No data migration; the OAuth
token/consent stores already exist and gain no new schema, only a new
`actor` field alongside issued tokens and a way to reach the consent step
via OIDC instead of the key form. Rollback is unsetting the env vars and
restarting.
