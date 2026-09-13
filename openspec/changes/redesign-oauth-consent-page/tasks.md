## 1. Branding and redirect destination

- [x] 1.1 Add `ConsentPageParams.serverHost`; pass it from `authorize.dart` via the existing `publicBaseUrl` helper
- [x] 1.2 Render a branded header (mark + host) and show the full `redirect_uri` before the identity step
- [x] 1.3 Tests: server host is shown; redirect_uri is shown in full and escaped

## 2. Cancel link

- [x] 2.1 Add `_cancelHref` building `redirect_uri` + `error=access_denied` (+ `state`) via the existing `appendQuery` helper
- [x] 2.2 Add a Cancel link next to the primary action in both the API-key form and the sign-in-link variant
- [x] 2.3 Tests: href correctness (with/without state, with an existing query string), presence in both variants

## 3. Verify

- [x] 3.1 `dart test`, `dart analyze`, `dart format` for the server
- [x] 3.2 `make test` / `make lint` / `make fmt` at the repo root
