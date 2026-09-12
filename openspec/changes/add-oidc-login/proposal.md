## Why

robot-notes has no user/account model: one shared static bearer API key
protects the REST API, the WebSocket, and even gates the app's own OAuth 2.1
authorization server. Humans currently prove they're allowed in by pasting
that raw secret in two places — the Flutter app's first-run setup screen, and
the MCP OAuth consent page, where "granting access" literally means re-typing
the shared secret into an HTML form. OIDC login lets a human authenticate
with their own identity provider instead, eliminating token-pasting for
people while leaving the key-based path agents and scripts already use
untouched.

## What Changes

- Add an OIDC relying-party capability to the server: one configured external
  issuer (discovery, PKCE + state + nonce, JWKS-verified ID token), enabled
  only when an issuer/client ID/client secret are all configured. Unset =
  today's behavior, unchanged.
- The existing OAuth 2.1 authorization server's consent step gains a second
  way to prove the resource owner's identity: when OIDC is configured, the
  consent page redirects through the OIDC login instead of asking for the
  raw static key. The paste-the-key form remains available when OIDC is not
  configured.
- The Flutter app becomes an OAuth client of its own server (as any MCP
  client already can be), offering "Sign in" via the authorization-code +
  PKCE flow (same-origin redirect on web, loopback redirect on desktop) as an
  alternative to pasting the static key on first run. Manual key entry stays
  available.
- **BREAKING** (spec-level; takes effect immediately, independent of whether
  OIDC is configured): a server-issued OAuth access token scoped to
  resource `<base>` (as opposed to `<base>/mcp`) may now authenticate REST
  and WebSocket requests, gated by `notes:read`/`notes:write` scope —
  previously OAuth tokens only ever worked against `/mcp`. This applies to
  any OAuth grant with that resource, not only ones completed via OIDC
  login — including, for example, a client that completes consent by
  pasting the static key but requests resource `<base>`.
- For any OAuth-authenticated session, the `X-Actor` value is ignored in
  favor of the display name captured at grant time — the verified ID
  token's `name`/`email` claim for an OIDC-backed grant, or the display
  name typed into the consent form otherwise — instead of trusted free
  text.

## Capabilities

### New Capabilities

- `oidc-login`: server-side OIDC relying-party configuration, discovery, the
  authorization redirect, and callback/token-verification behavior.

### Modified Capabilities

- `auth`: `bearerAuth()` accepts a second credential type — a valid,
  appropriately-scoped server-issued OAuth access token — on REST routes and
  the WebSocket handshake, not only `/mcp`. `X-Actor` derivation adds an
  OIDC-session case.
- `oauth-authorization`: the consent step branches on whether OIDC is
  configured; when it is, identity is proven via OIDC login rather than the
  static key form.
- `flutter-client`: the first-run flow gains an OIDC sign-in path alongside
  manual API key entry; secure storage persists OAuth tokens for
  OIDC-authenticated sessions.

## Impact

- New code: `server/lib/src/oidc/` (discovery, redirect, callback, ID-token
  verification), new CLI flags/env vars (`--oidc-issuer`/
  `ROBOT_NOTES_OIDC_ISSUER`, `--oidc-client-id`/`ROBOT_NOTES_OIDC_CLIENT_ID`,
  `--oidc-client-secret`/`ROBOT_NOTES_OIDC_CLIENT_SECRET`).
- Changed code: `server/lib/src/oauth/consent_page.dart`,
  `server/routes/oauth/authorize.dart`, `server/lib/src/auth_middleware.dart`,
  `server/lib/src/config.dart`, `app/lib/src/setup/setup_screen.dart`,
  `app/lib/src/config/config_store.dart`.
- New server dependency: `package:pointycastle`, used only for the ID
  token's RS256/ES256 signature verification — see design.md decision 3.
- Docker image / README / deployment docs gain the three new optional env
  vars.

## Non-goals

- Replacing the static key for agent/invite onboarding — unchanged.
- Mobile app OIDC login (custom URI scheme / app link) — desktop and web
  only in this change.
- Supporting more than one OIDC provider per deployment.
- Per-user authorization tiers or claims-based restriction (e.g. allowed
  email domain) — any successful OIDC login grants the same full access the
  static key already grants.
