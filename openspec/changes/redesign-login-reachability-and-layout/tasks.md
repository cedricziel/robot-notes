## 1. Layout

- [x] 1.1 Wrap the setup screen's content in a width-capped (420px), centered `Card`
- [x] 1.2 Test: the card's rendered width stays capped on a wide window

## 2. Live reachability check

- [x] 2.1 Add a `_Reachability` state machine (`idle`/`checking`/`ok`/`error`) and a generation-guarded `_checkReachability()` probing `GET /healthz`, scheduled on the same debounce as the existing OIDC capability check, on every platform
- [x] 2.2 Show a checking/ok/error indicator next to the server-URL field; never gate "Continue" on it
- [x] 2.3 Tests: checking/ok/error indicator states; a stale (earlier) response does not override a newer one

## 3. Manual-entry disclosure

- [x] 3.1 When sign-in is offered, collapse the API-key/display-name fields behind a "Use an API key instead" `TextButton`; tapping it reveals them
- [x] 3.2 When sign-in is not offered, keep manual entry always visible (unchanged)
- [x] 3.3 Tests: collapsed by default when sign-in is offered, expands on tap, always visible when sign-in is unavailable

## 4. Verify

- [x] 4.1 `flutter test`, `flutter analyze`, `dart format` for the app
- [x] 4.2 `make test` / `make lint` / `make fmt` at the repo root
