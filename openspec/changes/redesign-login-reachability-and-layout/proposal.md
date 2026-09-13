## Why

A UX review of the first-run setup screen found three problems: the form stretches edge-to-edge on a wide window, nothing checks the server URL before "Connect" is pressed (a typo only surfaces as a failure afterward), and — once sign-in is offered — the sign-in button and manual API-key entry compete for equal visual weight instead of sign-in being the clear primary path.

## What Changes

- The setup screen's content is wrapped in a width-capped, centered card (max 420px) instead of stretching to the window width.
- The server-URL field gets a live reachability check: a `GET /healthz` probe fires on the same debounce that already checks OIDC support, showing checking/reachable/unreachable next to the field. Purely informational — it does not gate "Continue"; full validation still happens on submit.
- When sign-in is offered (desktop/web, server supports OIDC), the API key and display-name fields start collapsed behind a "Use an API key instead" disclosure instead of being shown immediately below the sign-in button. When sign-in isn't offered, manual entry is unchanged — always visible, the only path.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: the first-run setup requirement gains the width-capped layout and the live reachability check as testable scenarios.

## Impact

- `app/lib/src/setup/setup_screen.dart`: width-capped `Card`, a `_Reachability` state machine with a generation-guarded `/healthz` probe, and a collapsed-by-default manual-entry disclosure when sign-in is offered.

## Non-goals

- No change to the two-step (server, then login) flow itself, or to `SetupController`'s validation-on-submit logic.
- No change to OIDC sign-in mechanics (`OidcSignInController`) — this only changes how its entry point is presented.
- Not fixing the pre-existing gap where OIDC sign-in isn't yet described in `openspec/specs/flutter-client/spec.md` at all (predates this change, out of scope here).
