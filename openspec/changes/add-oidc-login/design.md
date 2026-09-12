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

### 3. Hand-roll discovery/JWKS/claims; use `package:pointycastle` only for the signature primitive

The server verifies exactly one thing cryptographically: an ID token's
signature (fetched via the issuer's `/.well-known/openid-configuration` →
`jwks_uri`, RS256 or ES256 JWS), plus `iss`/`aud`/`exp`/`nonce` claim checks.
Discovery, JWKS fetch/cache, JWT structure parsing, and claim validation
stay hand-rolled (small, well-understood, and directly testable against
RFC 7517/7519 — the existing OAuth AS already hand-rolls comparable
primitives in `oauth_crypto.dart`). The one piece deliberately **not**
hand-rolled is the actual signature math: RSASSA-PKCS1-v1_5 verification is
tractable with Dart's built-in `BigInt.modPow`, but ECDSA (P-256) requires
elliptic-curve point arithmetic, which is a genuine correctness/security
risk to implement from scratch. `package:pointycastle` (the standard,
actively-maintained Dart/Flutter crypto primitives library) supplies RSA
and ECDSA signature verification for both algorithms — used for exactly
that one call, nothing else from it.

Alternatives considered:

- Hand-roll RSA (via `BigInt.modPow`) and drop ES256 support. Rejected per
  explicit product decision — ES256-configured providers (some Keycloak/
  Authentik deployments) should work too, and a split "RSA hand-rolled, EC
  via a library" implementation would be more code to maintain than one
  library call for both algorithms.
- A full OIDC/OAuth client package (e.g. `openid_client`). Rejected — this
  change only needs the signature-verification primitive, not discovery,
  session, or token-management logic this server already has its own
  (audited, tested) implementation of.

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

### 5. `X-Actor` for OAuth sessions comes from the grant, not the header

When a request authenticates via any server-issued OAuth access token —
not only an OIDC-derived one — the actor identity used for
locks/presence/`changed` events is the display name captured at grant
time and stored alongside the token record: the ID token's `name`
(falling back to `email`, then `sub`) for an OIDC-backed grant, or the
name typed into the consent form for a grant completed by pasting the
static key. Either way it is not read from a client-supplied `X-Actor`
header, which remains untrusted free text only for static-key requests
made directly against the REST/WS API (not through an OAuth grant).

## Risks / Trade-offs

- [The external IdP becomes a hard runtime dependency for human login] →
  Mitigated by keeping the static key path fully independent — an IdP outage
  blocks new human logins, not agents, scripts, or already-issued sessions.
- [Loopback-redirect desktop login can be blocked by strict OS firewalls or
  fail if the ephemeral port collides] → Mitigate by trying a small fixed
  range and surfacing a clear error with the manual-key fallback still
  available in the same screen.
- [JWT verification is a common source of auth bugs (alg confusion, missing
  `aud` check, accepting `none`)] → The signature math itself uses
  `pointycastle`, not hand-rolled crypto; the hand-rolled part (structure
  parsing, claim checks) is mitigated with an explicit allowlist of
  accepted signing algorithms (RS256, ES256 only, no `none`, checked before
  any signature verification is attempted), mandatory `iss`/`aud`/`exp`/
  `nonce` checks, and a dedicated test suite covering each rejection case
  per RFC 7519 §4.1 / OIDC Core §3.1.3.7.
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
