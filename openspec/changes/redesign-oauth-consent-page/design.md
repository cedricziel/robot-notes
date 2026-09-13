## Context

`renderConsentPage` (server/lib/src/oauth/consent_page.dart) is a self-contained HTML string with no external resources and no JavaScript, by design — see the function's existing doc comment. See proposal.md - Why.

## Goals / Non-Goals

**Goals:**

- Give the page a visible connection to robot-notes and to the destination the user is about to be sent back to.
- Let the user decline without leaving the page.

**Non-Goals:**

- No new server route or form field for declining.
- No change to what the page looks like for a JS-disabled or ancient browser beyond plain CSS (the no-JS, no-external-resource constraint is unchanged).

## Decisions

- **Cancel is a plain `<a>` link built server-side, not a form submission.** The server already has every value a denial redirect needs (`redirectUri`, `state`) at render time, and `_redirectWithError` in the authorize route already does the exact same `error=access_denied`-style redirect for validation failures — reusing the same `appendQuery` helper keeps the two denial paths consistent without adding a route.
- **The server host comes from the existing `publicBaseUrl(context)` helper**, not a new config field — it already resolves the canonical host (configured `--public-url`, or `X-Forwarded-Proto`/`Host` headers) for OAuth metadata and redirects, so the consent page's branding uses the same source of truth as the issuer it's granting access under.
- **The redirect destination is shown in full**, not just its host. A truncated host-only display would satisfy the letter of "shown before you decide" but not give a client-specific path or query enough to actually distinguish one client from another sharing a host.

## Risks / Trade-offs

- [A very long `redirect_uri` could wrap awkwardly in the fixed-width card] → Acceptable; `word-break: break-all` on the `<code>` element keeps it from overflowing the page.
