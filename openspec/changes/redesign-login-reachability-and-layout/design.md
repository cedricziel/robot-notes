## Context

`SetupScreen` already debounces on the server-URL field to silently probe `/.well-known/oauth-authorization-server` for OIDC support (`_checkCapabilities`), gated to desktop/web. See proposal.md - Why.

## Goals / Non-Goals

**Goals:**

- Surface a URL problem as early as typing, not only after "Connect" fails.
- Make the primary action (sign-in, when offered) visually unambiguous.

**Non-Goals:**

- No change to `SetupController.submit`'s own validation (`/healthz` then `/notes?limit=1`) — the new check is a separate, best-effort probe.
- No change to the OIDC capability check's own gating (still desktop/web only).

## Decisions

- **A second, independent debounced probe (`_checkReachability`), not a reuse of `_checkCapabilities`.** Reachability must work on every platform (mobile included), while the OIDC capability check stays desktop/web-only — coupling them would either skip reachability on mobile or run an unnecessary OIDC probe there. Both are scheduled from the same `Timer` in `_onBaseUrlChanged` so there's only one debounce window.
- **A generation counter guards the reachability result**, mirroring the note editor's heartbeat/autosave scheduling. Two requests can be in flight if the user keeps typing; without a guard, a slow response to an earlier (now-stale) URL could land after a fast response to the current one and show the wrong status.
- **The probe is best-effort and never blocks "Continue."** `Continue`'s existing gate (`isSecureBaseUrl`) is unchanged. A false negative (e.g., a firewall blocking `/healthz` but not `/notes`) would otherwise strand a valid setup behind a misleading red indicator.
- **The disclosure is a plain boolean (`_manualEntryExpanded`), not tied to `showSignIn`'s own lifecycle.** Once a user expands it, it stays expanded even if `showSignIn` state changes underneath (e.g. a slow capability response resolving after the user already opted into manual entry) — collapsing on them mid-input would be jarring. The converse race (fields visible because `showSignIn` starts false, then capabilities resolve true and collapse fields the user hadn't touched yet) is accepted as a minor, narrow-window edge case.

## Risks / Trade-offs

- [A user typing quickly could see the reachability indicator flicker between checking/ok/error] → Acceptable; it settles once typing pauses, same debounce window as the existing OIDC check.
- [The `/healthz` probe adds one more request per debounce tick] → Negligible; it's a cheap unauthenticated endpoint the server already exposes for `SetupController.submit`'s own first step.
