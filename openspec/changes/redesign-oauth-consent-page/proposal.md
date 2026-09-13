## Why

A UX review of the MCP OAuth consent page found three problems: it renders as an unstyled default browser form with no visual trust signal after a Material app, it never shows the client's redirect destination for the user to check the request against, and "Authorize" is the only action on the page — declining means abandoning it rather than clicking Cancel.

## What Changes

- The consent page gets a small branded header (a mark plus this server's own host) and real typography/colors instead of unstyled default form controls.
- The client's `redirect_uri` is shown in full before the user decides.
- A "Cancel" link sits next to the primary action (the "Allow" button, or the "Sign in with your identity provider" link when OIDC is configured). It points directly at `redirect_uri` with `error=access_denied` appended — the standard OAuth denial response — with no new server round-trip.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `oauth-authorization`: the consent-page requirement gains the branding, redirect-destination-display, and Cancel-link scenarios.

## Impact

- `server/lib/src/oauth/consent_page.dart`: new `ConsentPageParams.serverHost`, updated markup/styles, a `_cancelHref` helper built with the existing `appendQuery`.
- `server/routes/oauth/authorize.dart`: passes `serverHost` (derived via the existing `publicBaseUrl` helper) into `ConsentPageParams`.

## Non-goals

- No change to the consent-submission logic (`POST /oauth/authorize`, API-key check, throttling) — Cancel is a pure link, not a new form action.
- No change to OIDC sign-in mechanics — only how "Sign in" is presented alongside the new Cancel link.
