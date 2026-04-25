## 1. Repository scaffold

- [x] 1.1 Initialize a Dart **pub workspace** (Dart 3.5+ feature) at the repo root: top-level `pubspec.yaml` with `workspace:` listing `server/`, `app/`, and `shared/`
- [x] 1.2 Create the three member packages — `server/` (plain Dart, will be Dart Frog), `app/` (Flutter), `shared/` (pure Dart, no Flutter dep) — each with its own `pubspec.yaml` declaring `resolution: workspace`
- [x] 1.3 Wire `server/` and `app/` to depend on `shared/` via `path: ../shared`; verify `dart pub get` at the root resolves all three with a single shared `.dart_tool/`
- [x] 1.4 Populate `shared/` with the initial API-contract types: `Note`, `NoteMeta`, `Lock`, `InviteSummary`, error envelope + `ErrorCode` enum, route path constants, WS envelope types (`AuthMsg`, `SubscribeMsg`, `PresenceEvent`, `LockEvent`, `ChangedEvent`, `PingMsg`, `PongMsg`, `ErrorMsg`) — each with `fromJson`/`toJson`
- [x] 1.5 Write failing tests in `shared/` covering JSON round-trips for every DTO and event envelope
- [x] 1.6 Add `Makefile` targets `lint`, `format`, `test`, `run-server`, `run-app` that operate over the workspace
- [x] 1.7 Add a top-level README stub with how to run server and app locally
- [x] 1.8 Verify `shared/` does NOT depend on `package:flutter`, `dart_frog`, or anything server-only (lint or test)

## 2. Server scaffold (Dart Frog)

- [x] 2.1 Initialize a Dart Frog project under `server/`
- [x] 2.2 Add core dependencies: `dart_frog`, `package:sqlite3`, `package:yaml`, `package:ulid`, `package:args`, `package:logging`, and `shared` via `path: ../shared`
- [x] 2.3 Add dev dependencies: `test`, `mocktail`, `http`, `web_socket_channel` (for client-side test helpers)
- [x] 2.4 Configure `analysis_options.yaml` with strict-mode lints
- [x] 2.5 Verify `dart_frog dev` boots and serves a default route

## 3. CLI argument and config plumbing

- [x] 3.1 Write failing test: `Config.fromArgs([])` exits with non-zero code when no key is configured
- [x] 3.2 Write failing test: `Config.fromArgs(['--api-key','rn_x'])` returns a config with apiKey `'rn_x'`
- [x] 3.3 Write failing test: env var fallback returns key when CLI arg absent
- [x] 3.4 Write failing test: CLI arg wins over env var when both present
- [x] 3.5 Write failing test: `--data-dir`, `--port`, `--lock-ttl-seconds` parse correctly with defaults
- [x] 3.6 Implement `Config` class to make tests pass
- [x] 3.7 Wire `Config` into the server entrypoint; abort startup with a helpful message if invalid

## 4. Auth middleware

- [x] 4.1 Write failing test: request with no Authorization header → 401 JSON `{error:"unauthorized"}`
- [x] 4.2 Write failing test: request with malformed Authorization → 401
- [x] 4.3 Write failing test: request with mismatched bearer key → 401
- [x] 4.4 Write failing test: request with correct bearer key proceeds to handler
- [x] 4.5 Write failing test: `GET /healthz` returns 200 without any auth header
- [x] 4.6 Write failing test: comparison is constant-time (use a property test or timing-leak guard)
- [x] 4.7 Implement bearer-key middleware to make tests pass
- [x] 4.8 Register middleware globally with `/healthz` exempted

## 5. Actor identity middleware

- [x] 5.1 Write failing test: `X-Actor: alice` results in handler context having `actor == "alice"`
- [x] 5.2 Write failing test: missing `X-Actor` results in `actor == "unknown"`
- [x] 5.3 Write failing test: empty `X-Actor` results in `actor == "unknown"`
- [x] 5.4 Implement actor middleware exposing `request.context.read<Actor>()`

## 6. Health endpoint

- [ ] 6.1 Write failing test: `GET /healthz` returns 200 with body `{"status":"ok"}`
- [ ] 6.2 Implement `routes/healthz.dart`

## 7. Frontmatter parser

- [ ] 7.1 Write failing test: parse a file with `---` frontmatter returns map + body
- [ ] 7.2 Write failing test: parse a file without frontmatter returns empty map + full body
- [ ] 7.3 Write failing test: malformed frontmatter throws a typed exception
- [ ] 7.4 Write failing test: serialize map + body produces a round-trippable file
- [ ] 7.5 Write failing test: round-trip preserves unknown keys in stable order
- [ ] 7.6 Implement frontmatter parse/serialize using `package:yaml` + a thin wrapper

## 8. Storage primitives

- [ ] 8.1 Write failing test: `Storage.list()` empty when content dir is empty
- [ ] 8.2 Write failing test: `Storage.create(title, content, actor)` writes a file with frontmatter and version 1
- [ ] 8.3 Write failing test: created file uses ULID filename and includes `id`, `created_at`, `updated_at`
- [ ] 8.4 Write failing test: `Storage.read(id)` returns the parsed note
- [ ] 8.5 Write failing test: `Storage.update(id, title, content, ifMatch=v)` succeeds when version matches and bumps to v+1
- [ ] 8.6 Write failing test: update with stale `ifMatch` throws `VersionConflict` carrying current state
- [ ] 8.7 Write failing test: `Storage.delete(id)` removes the file and returns ok
- [ ] 8.8 Write failing test: writes are atomic (simulate crash between tmp write and rename, file remains intact)
- [ ] 8.9 Write failing test: concurrent updates to the same id are serialized
- [ ] 8.10 Write failing test: updates preserve unknown frontmatter keys
- [ ] 8.11 Implement `Storage` over a real temp directory using tmp+fsync+rename and per-id mutex

## 9. In-memory metadata index

- [ ] 9.1 Write failing test: `MetaIndex.scan(dir)` populates entries from existing files
- [ ] 9.2 Write failing test: `MetaIndex` exposes paginated cursor-based listing sorted by id
- [ ] 9.3 Write failing test: `MetaIndex.upsert` reflects new metadata immediately
- [ ] 9.4 Write failing test: `MetaIndex.remove` deletes the entry
- [ ] 9.5 Write failing test: malformed file is skipped and logged but doesn't throw
- [ ] 9.6 Implement `MetaIndex` with map + sorted-key list

## 10. Lock manager

- [ ] 10.1 Write failing test: `LockManager.acquire(id, actor)` succeeds when unlocked
- [ ] 10.2 Write failing test: acquire by different actor while locked → `LockedException` with current state
- [ ] 10.3 Write failing test: acquire by same actor while locked extends TTL (idempotent)
- [ ] 10.4 Write failing test: acquire on expired lock succeeds
- [ ] 10.5 Write failing test: `heartbeat` by holder extends `expires_at`
- [ ] 10.6 Write failing test: heartbeat by non-holder throws
- [ ] 10.7 Write failing test: heartbeat on expired lock throws `NotFound`
- [ ] 10.8 Write failing test: `release` by holder clears state
- [ ] 10.9 Write failing test: release by non-holder throws
- [ ] 10.10 Write failing test: release of expired/missing lock is idempotent
- [ ] 10.11 Write failing test: `lockOf(id)` returns null for expired locks
- [ ] 10.12 Write failing test: lock state transitions emit events on a stream the broadcaster can subscribe to
- [ ] 10.13 Implement `LockManager` purely in-memory using a `Map<String, Lock>` and a `Stream<LockEvent>`

## 11. Notes API routes (HTTP)

- [ ] 11.1 Write failing test: `GET /notes` returns paginated metadata, default limit 50
- [ ] 11.2 Write failing test: `GET /notes?limit=200` is allowed; `limit=201` is clamped to 200
- [ ] 11.3 Write failing test: cursor pagination returns subsequent pages and final page has `next_cursor: null`
- [ ] 11.4 Write failing test: list items omit `content` field
- [ ] 11.5 Write failing test: `POST /notes` with valid body returns 201 and full record with `version: 1`
- [ ] 11.6 Write failing test: `POST /notes` with empty/missing title returns 400
- [ ] 11.7 Write failing test: `GET /notes/{id}` returns 200 with full record
- [ ] 11.8 Write failing test: `GET /notes/{id}` returns 404 with `{error:"not_found"}` for unknown id
- [ ] 11.9 Write failing test: `GET /notes/{id}` includes `lock` when locked
- [ ] 11.10 Write failing test: `PUT /notes/{id}` without `If-Match` returns 428
- [ ] 11.11 Write failing test: `PUT /notes/{id}` with non-numeric `If-Match` returns 400
- [ ] 11.12 Write failing test: `PUT /notes/{id}` with stale `If-Match` returns 409 with current state
- [ ] 11.13 Write failing test: `PUT /notes/{id}` while locked by another actor returns 423
- [ ] 11.14 Write failing test: `PUT /notes/{id}` by lock holder with matching `If-Match` succeeds
- [ ] 11.15 Write failing test: `DELETE /notes/{id}` returns 204 and removes file
- [ ] 11.16 Write failing test: `DELETE /notes/{id}` while locked by another actor returns 423
- [ ] 11.17 Write failing test: `DELETE /notes/{id}` for unknown id returns 404
- [ ] 11.18 Write failing test: every error response has a JSON body with stable `error` code
- [ ] 11.19 Implement the five route handlers using `Storage`, `MetaIndex`, and `LockManager`

## 12. Lock API routes (HTTP)

- [ ] 12.1 Write failing test: `POST /notes/{id}/lock` on unlocked note returns 200 with holder/expiry
- [ ] 12.2 Write failing test: `POST /notes/{id}/lock` blocked by other actor returns 423
- [ ] 12.3 Write failing test: `POST /notes/{id}/lock` by same actor extends TTL (idempotent 200)
- [ ] 12.4 Write failing test: `PUT /notes/{id}/lock` heartbeat by holder extends expiry
- [ ] 12.5 Write failing test: heartbeat by non-holder returns 423
- [ ] 12.6 Write failing test: heartbeat on expired lock returns 404
- [ ] 12.7 Write failing test: `DELETE /notes/{id}/lock` by holder returns 204
- [ ] 12.8 Write failing test: release by non-holder returns 423
- [ ] 12.9 Write failing test: release of expired/missing lock returns 204 (idempotent)
- [ ] 12.10 Implement the three lock route handlers

## 13. WebSocket endpoint

- [ ] 13.1 Write failing test: connection without auth message within 2s closes with code 4001 and reason `auth_timeout`
- [ ] 13.2 Write failing test: auth with wrong key closes with 4001 and reason `auth_failed`
- [ ] 13.3 Write failing test: successful auth gets `auth_ok` and binds actor identity
- [ ] 13.4 Write failing test: missing `actor` in auth defaults to `"unknown"`
- [ ] 13.5 Write failing test: subscribe before auth is silently ignored, no events delivered
- [ ] 13.6 Write failing test: per-note subscribe receives only events for that id
- [ ] 13.7 Write failing test: wildcard subscribe receives events for any id
- [ ] 13.8 Write failing test: unsubscribe stops further delivery for that id
- [ ] 13.9 Write failing test: subscribing to a note triggers a `presence` event for prior subscribers
- [ ] 13.10 Write failing test: disconnect updates presence on remaining subscribers
- [ ] 13.11 Write failing test: same actor on two connections appears once in presence
- [ ] 13.12 Write failing test: `lock` event fires for acquire, heartbeat, release, expiry
- [ ] 13.13 Write failing test: `changed` event fires on create/update/delete with correct shape
- [ ] 13.14 Write failing test: `changed` events do NOT include note content
- [ ] 13.15 Write failing test: binary frame closes connection with 1003
- [ ] 13.16 Write failing test: ping/pong echo with same id
- [ ] 13.17 Write failing test: unknown message type yields `{type:"error","error":"unknown_type",...}` and keeps connection open
- [ ] 13.18 Write failing test: slow consumer is dropped without blocking the broadcast loop
- [ ] 13.19 Implement the WS handler, broadcaster, and presence tracker

## 14. Search index (FTS5)

- [ ] 14.1 Write failing test: missing `search.db` is rebuilt on startup from `content/`
- [ ] 14.2 Write failing test: corrupt `search.db` (failed `PRAGMA integrity_check`) is rebuilt on startup
- [ ] 14.3 Write failing test: healthy `search.db` matching schema is reused (no rebuild)
- [ ] 14.4 Write failing test: schema mismatch triggers rebuild
- [ ] 14.5 Write failing test: rebuild logs the count of indexed notes
- [ ] 14.6 Write failing test: `SearchIndex.upsert(id,title,content)` makes the row searchable
- [ ] 14.7 Write failing test: `SearchIndex.delete(id)` removes the row
- [ ] 14.8 Write failing test: stemmed match (`run` matches `running`)
- [ ] 14.9 Write failing test: case-insensitive match
- [ ] 14.10 Write failing test: phrase query `"release notes"` works
- [ ] 14.11 Write failing test: prefix query `archi*` works
- [ ] 14.12 Write failing test: invalid FTS5 query returns `invalid_query` error from the layer
- [ ] 14.13 Write failing test: results include `id`, `title`, `snippet`, `rank` and are ordered by rank ascending
- [ ] 14.14 Write failing test: snippet contains `<mark>...</mark>` markers
- [ ] 14.15 Implement `SearchIndex` over `package:sqlite3`

## 15. Search API route

- [ ] 15.1 Write failing test: `GET /search?q=foo` returns ranked items
- [ ] 15.2 Write failing test: `GET /search` (no q) → 400
- [ ] 15.3 Write failing test: `GET /search?q=` (empty) → 400 with `empty_query`
- [ ] 15.4 Write failing test: `limit` defaults to 20, clamps at 100
- [ ] 15.5 Write failing test: invalid FTS query → 400 with `invalid_query`
- [ ] 15.6 Write failing test: unauthenticated request → 401
- [ ] 15.7 Implement the route delegating to `SearchIndex`

## 16. Invite store and agent-onboarding endpoints

- [ ] 16.1 Write failing test: `InviteStore.mint(label, ttl)` writes `data/invites/<token>.json` atomically (tmp+fsync+rename) with the documented schema
- [ ] 16.2 Write failing test: minted token is URL-safe and carries at least 128 bits of entropy
- [ ] 16.3 Write failing test: `InviteStore.list()` returns all on-disk invites with `expired` flag computed against the current clock
- [ ] 16.4 Write failing test: `InviteStore.get(token)` returns the invite or null for missing
- [ ] 16.5 Write failing test: `InviteStore.burn(token)` sets `burned_at` atomically and returns the previous (unburned) state
- [ ] 16.6 Write failing test: `InviteStore.burn(token)` is exclusive — under simulated concurrent calls exactly one returns the unburned state, others return `AlreadyBurned`
- [ ] 16.7 Write failing test: `InviteStore.revoke(token)` deletes the file and returns 204; missing token returns 404
- [ ] 16.8 Write failing test: malformed JSON in `data/invites/` is skipped on listing and logged
- [ ] 16.9 Implement `InviteStore` (token gen, file IO, atomic burn) over a real temp directory
- [ ] 16.10 Write failing test: `POST /invites` (Bearer) with `{}` returns 201 with `token`, `url`, `expires_at`, `single_use:true`, default 24h TTL
- [ ] 16.11 Write failing test: `POST /invites` honors `label` and `ttl_seconds`
- [ ] 16.12 Write failing test: `POST /invites` rejects `ttl_seconds > 2592000` with 400 `invalid_ttl`
- [ ] 16.13 Write failing test: `POST /invites` without auth → 401
- [ ] 16.14 Write failing test: `GET /invites` (Bearer) returns array with all invites including `expired` flag
- [ ] 16.15 Write failing test: `GET /invites` without auth → 401
- [ ] 16.16 Write failing test: `DELETE /invites/{token}` (Bearer) returns 204 and removes the file
- [ ] 16.17 Write failing test: `DELETE /invites/{unknown}` returns 404 `invite_not_found`
- [ ] 16.18 Write failing test: `GET /invites/{token}/onboarding.txt` (no auth) on unburned, unexpired invite returns 200 `text/plain; charset=utf-8` and atomically burns
- [ ] 16.19 Write failing test: bundle body contains the configured api key, server base URL, and a recommended `X-Actor` derived from the invite label
- [ ] 16.20 Write failing test: bundle body includes the API surface guide (notes CRUD, lock endpoints, search, /ws)
- [ ] 16.21 Write failing test: second fetch of the same token returns 410 `invite_burned`
- [ ] 16.22 Write failing test: expired invite returns 404 `invite_not_found`
- [ ] 16.23 Write failing test: simultaneous fetches of the same unburned token — exactly one client receives 200, the other 410
- [ ] 16.24 Write failing test: response on the onboarding endpoint does NOT include `Access-Control-Allow-Credentials: true`
- [ ] 16.25 Write failing test: server logs do not include the full token nor the bundle body (capture log stream and assert)
- [ ] 16.26 Implement the four invite route handlers (`POST /invites`, `GET /invites`, `DELETE /invites/{token}`, `GET /invites/{token}/onboarding.txt`)
- [ ] 16.27 Implement the onboarding bundle template — a single Markdown-compatible plain-text document compiled from the spec'd API surface

## 17. Wire-up: write path triggers broadcast and search index update

- [ ] 17.1 Write failing test: successful create updates `MetaIndex`, `SearchIndex`, and emits `changed{action:"created"}`
- [ ] 17.2 Write failing test: successful update updates all three and emits `changed{action:"updated"}`
- [ ] 17.3 Write failing test: successful delete removes from all three and emits `changed{action:"deleted"}`
- [ ] 17.4 Write failing test: search index update is transactional with the file write (no half-state on failure)
- [ ] 17.5 Write failing test: WS broadcast failure does NOT roll back the file write
- [ ] 17.6 Implement an application service that orchestrates Storage + MetaIndex + SearchIndex + Broadcaster

## 18. Server integration test (end-to-end)

- [ ] 18.1 Write failing test: full lifecycle — create, read, lock, update, search, delete — over real HTTP
- [ ] 18.2 Write failing test: two clients see each other's presence and changes over real WS
- [ ] 18.3 Write failing test: 409 path under simulated concurrency
- [ ] 18.4 Write failing test: lock TTL expiry observed via lazy-evaluation on next access
- [ ] 18.5 Write failing test: end-to-end invite flow — operator mints invite, agent fetches `onboarding.txt` once, second fetch is 410, agent uses returned key to GET `/notes`
- [ ] 18.6 Run the full integration suite green

## 19. Flutter app scaffold

- [ ] 19.1 `flutter create app` configured for android/ios/macos/windows/linux/web
- [ ] 19.2 Add core dependencies: `http`, `web_socket_channel`, `flutter_secure_storage`, `riverpod` (or chosen state mgmt), and `shared` via `path: ../shared`
- [ ] 19.3 Add dev dependencies: `flutter_test`, `mocktail`
- [ ] 19.4 Configure `analysis_options.yaml` with strict-mode lints
- [ ] 19.5 Verify each platform target builds with `flutter build`

## 20. Configuration storage and first-run flow

- [ ] 20.1 Write failing widget test: setup screen renders three inputs (URL, key, actor)
- [ ] 20.2 Write failing test: invalid key validation surfaces a 401 message and does not persist
- [ ] 20.3 Write failing test: unreachable server surfaces a network error and does not persist
- [ ] 20.4 Write failing test: successful validation persists to secure storage and routes to list
- [ ] 20.5 Write failing test: API key is never written to logs (capture log stream and assert)
- [ ] 20.6 Implement setup screen + secure storage adapter

## 21. API client (Dart, in `app/`)

- [ ] 21.1 Write failing test: client adds `Authorization: Bearer ...` and `X-Actor: ...` to every request
- [ ] 21.2 Write failing test: 401 surfaces a typed `Unauthorized` exception
- [ ] 21.3 Write failing test: 409 surfaces `VersionConflict` with current state
- [ ] 21.4 Write failing test: 423 surfaces `Locked` with holder/expiry
- [ ] 21.5 Write failing test: list, read, create, update, delete, lock-acquire/heartbeat/release, search are exercised
- [ ] 21.6 Implement client against fake HTTP

## 22. WebSocket client (Dart, in `app/`)

- [ ] 22.1 Write failing test: connect → send auth message within 100ms after open
- [ ] 22.2 Write failing test: re-connect on disconnect with exponential backoff (mockable clock)
- [ ] 22.3 Write failing test: re-auth and re-subscribe on each successful reconnect
- [ ] 22.4 Write failing test: events are exposed as a typed `Stream<NoteEvent>`
- [ ] 22.5 Write failing test: stale views (>5s offline) trigger explicit refresh signal
- [ ] 22.6 Implement WS client wrapper

## 23. Notes list view

- [ ] 23.1 Write failing widget test: initial render fetches first page
- [ ] 23.2 Write failing widget test: pull-to-refresh re-fetches first page
- [ ] 23.3 Write failing widget test: scrolling past end fetches next cursor page
- [ ] 23.4 Write failing widget test: `changed{action:"updated"}` updates entry without manual refresh
- [ ] 23.5 Write failing widget test: `changed{action:"created"}` prepends entry
- [ ] 23.6 Write failing widget test: `changed{action:"deleted"}` removes entry
- [ ] 23.7 Implement list view backed by API client + WS stream

## 24. Note view (read + edit + lock)

- [ ] 24.1 Write failing widget test: open note → calls `GET /notes/{id}` and subscribes via WS
- [ ] 24.2 Write failing widget test: enter edit mode → acquires lock; on 423 stays read-only with banner
- [ ] 24.3 Write failing widget test: heartbeat is sent at half-TTL while editing
- [ ] 24.4 Write failing widget test: save sends `PUT` with `If-Match` of last-loaded version
- [ ] 24.5 Write failing widget test: 409 presents reconcile UI with server state and local edits
- [ ] 24.6 Write failing widget test: 423 mid-edit switches to read-only with holder banner
- [ ] 24.7 Write failing widget test: closing the editor releases the lock
- [ ] 24.8 Write failing widget test: presence indicator updates on `presence` events
- [ ] 24.9 Write failing widget test: lock indicator updates on `lock` events
- [ ] 24.10 Implement note view

## 25. Search view

- [ ] 25.1 Write failing widget test: typing triggers a debounced `GET /search` after ~250ms
- [ ] 25.2 Write failing widget test: emptying input clears results and issues no request
- [ ] 25.3 Write failing widget test: `<mark>` markers in snippets are visually highlighted
- [ ] 25.4 Write failing widget test: tapping a result navigates to the note view
- [ ] 25.5 Implement search view

## 26. Conventional commits enforcement

- [ ] 26.1 Add `commitlint` (or `cz-cli` / `conform`) configured for conventional-commits at the repo root
- [ ] 26.2 Add a `commit-msg` git hook (via `lefthook`, `husky`, or a plain `.githooks/` directory) that invokes the linter
- [ ] 26.3 Document hook installation in `CONTRIBUTING.md` (allowed types, breaking-change syntax, examples)
- [ ] 26.4 Add a `.github/workflows/commitlint.yml` (or fold into `ci.yml`) that lints PR titles and commits
- [ ] 26.5 Verify locally: a non-conforming commit message is rejected by the hook

## 27. Server Dockerfile

- [ ] 27.1 Write `server/Dockerfile` with a multi-stage build (builder + slim runtime), pinning each `FROM` by digest
- [ ] 27.2 Configure non-root user (`USER 10001` or named user), `WORKDIR /app`, `VOLUME /data`, `EXPOSE 8080`
- [ ] 27.3 Implement `HEALTHCHECK` invoking `/healthz` (e.g. `CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1`)
- [ ] 27.4 Add OCI labels: `org.opencontainers.image.source`, `.revision`, `.version`, `.created`, `.licenses`
- [ ] 27.5 Add `server/.dockerignore` excluding tests, dev artifacts, IDE files, and `data/`
- [ ] 27.6 Manual verification: `docker build server/` succeeds locally, `docker run` accepts `--api-key` and serves `/healthz`
- [ ] 27.7 Manual verification: container runs as non-root (`docker run --rm <img> id -u` returns non-zero)

## 28. CI workflow (test + lint + format + build dry-run)

- [ ] 28.1 Create `.github/workflows/ci.yml` triggered on `pull_request` and `push: { branches: [main] }`
- [ ] 28.2 Job: setup Dart + Flutter, run `dart pub get` for `server/` and `app/`
- [ ] 28.3 Job step: `make lint` (strict-mode analyzer) for both packages
- [ ] 28.4 Job step: `make format` and verify no diff (`dart format --set-exit-if-changed`)
- [ ] 28.5 Job step: `make test` for both packages (server unit + integration; app widget + unit)
- [ ] 28.6 Job: `docker buildx build --platform linux/amd64 server/` (no push) to validate Dockerfile each PR
- [ ] 28.7 Configure required status checks on `main` (manual repo settings step, document in RELEASING.md)

## 29. release-please configuration

- [ ] 29.1 Create `release-please-config.json` at repo root in manifest mode declaring component `robot-notes-server` (root or `server/`-rooted depending on layout)
- [ ] 29.2 Create `.release-please-manifest.json` initialized to `{ ".": "0.0.0" }` (or per-component map)
- [ ] 29.3 Create `.github/workflows/release-please.yml` triggered on `push: { branches: [main] }` invoking `googleapis/release-please-action@v4` with the config
- [ ] 29.4 Declare workflow `permissions: { contents: write, pull-requests: write }`
- [ ] 29.5 Verify locally with a dry run or by reviewing the action's first opened PR after merging the bootstrap commit

## 30. Publish workflow (ghcr multi-arch)

- [ ] 30.1 Create `.github/workflows/publish.yml` triggered by release-please's tag-create event (or by `release: { types: [published] }`) and by `push: { branches: [main] }` for previews
- [ ] 30.2 Declare `permissions: { contents: read, packages: write }`
- [ ] 30.3 Step: `docker/setup-qemu-action`
- [ ] 30.4 Step: `docker/setup-buildx-action`
- [ ] 30.5 Step: `docker/login-action` with `registry: ghcr.io`, `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}`
- [ ] 30.6 Step: `docker/metadata-action` configuring tags for releases (`vX.Y.Z`, `X.Y`, `X`, `latest`, `sha-<7>`) and previews (`main`, `sha-<7>`)
- [ ] 30.7 Step: `docker/build-push-action` with `platforms: linux/amd64,linux/arm64`, `push: true`, and the metadata-action outputs
- [ ] 30.8 Verify: tag a test pre-release (e.g. `v0.0.1-rc1`) and confirm both architectures appear under the same digest (`docker manifest inspect`)
- [ ] 30.9 One-time post-publish: set the ghcr package visibility to public and link to the source repo (document in RELEASING.md)

## 31. Dependabot configuration

- [ ] 31.1 Create `.github/dependabot.yml` with four `updates:` entries (`pub` × `server/`, `pub` × `app/`, `github-actions` × `/`, `docker` × `server/`)
- [ ] 31.2 Configure `schedule.interval: weekly` for each ecosystem
- [ ] 31.3 Configure `groups:` blocks for minor/patch updates per ecosystem to reduce PR noise
- [ ] 31.4 Add reviewers/labels per ecosystem (e.g. `dependencies`, `area:server`, `area:app`)
- [ ] 31.5 Manual verification: enable Dependabot in repo settings, observe initial scan, confirm no warnings in the Dependabot dashboard

## 32. Release runbook documentation

- [ ] 32.1 Add `RELEASING.md` covering: conventional-commits cheatsheet, how to read release-please's release PR, when/how to merge
- [ ] 32.2 Document the one-time ghcr post-publish step (set visibility public, link to repo)
- [ ] 32.3 Document hotfix procedure (`fix:` commit → release-please patch PR → merge → publish)
- [ ] 32.4 Document the tag scheme (`vX.Y.Z`, `X.Y`, `X`, `latest`, `sha-<7>`, `main`) and what each is for
- [ ] 32.5 Add a "first release" walkthrough so the very first contributor sees a coherent path from initial commit to `v0.1.0`
- [ ] 32.6 Document the agent-onboarding flow for operators: how to mint an invite (`curl -X POST .../invites`), how to share the URL, that the URL is single-use and as sensitive as the bearer key, and how to revoke

## 33. Bootstrap and verify the pipeline end-to-end

- [ ] 33.1 Land an initial conformant commit (`feat: initial server scaffold`) on `main`
- [ ] 33.2 Verify release-please opens its first release PR proposing `0.1.0`
- [ ] 33.3 Merge the release PR and verify a `v0.1.0` (or component-prefixed) tag and GitHub release are created
- [ ] 33.4 Verify the publish workflow fires on the new tag, builds multi-arch images, and pushes the canonical tag set to ghcr
- [ ] 33.5 Verify `docker pull ghcr.io/<owner>/robot-notes-server:v0.1.0` works on at least one machine and `docker run` exposes a healthy server
- [ ] 33.6 Land a follow-up `fix:` commit and verify the next release PR proposes `0.1.1`

## 34. Documentation, polish, and ship gate

- [ ] 34.1 README: how to run server with `--api-key` and `--data-dir`
- [ ] 34.2 README: how to point the Flutter app at a server
- [ ] 34.3 README: how to run the server via Docker (`docker run -e ROBOT_NOTES_API_KEY=... -v $(pwd)/data:/data -p 8080:8080 ghcr.io/<owner>/robot-notes-server:latest`)
- [ ] 34.4 README: how to onboard an agent (mint invite via `POST /invites`, share the URL, agent fetches `onboarding.txt` once)
- [ ] 34.5 Document the API in `server/API.md` (endpoints, error codes, WS protocol, invite endpoints)
- [ ] 34.6 Document data layout in `server/STORAGE.md` (frontmatter schema, paths, atomicity, `data/invites/` schema)
- [ ] 34.7 Run `make lint` and `make format` on both server and app; resolve all warnings
- [ ] 34.8 Confirm full test suite is green for server and app
- [ ] 34.9 Smoke test: spin up server (locally and via published image), build Flutter for one desktop platform, walk through happy path manually
- [ ] 34.10 Smoke test: mint an invite against the running server, fetch `onboarding.txt` once with `curl`, verify the bundle is readable, confirm the second fetch returns 410

## Definition of Done

- All checklist items above are checked.
- Every requirement and scenario in `specs/**/spec.md` has at least one corresponding test (server-side `dart test` and/or Flutter widget/integration test).
- `make lint` and `make format` exit cleanly on both the server and the Flutter app.
- Manual smoke test performed: a fresh checkout can run server and Flutter app and exercise the full happy path (create, search, edit with lock, save, see another client receive WS updates).
- The change has been validated with `openspec validate add-mvp-foundation --strict` (after `tasks.md` is committed) and shows no errors.
- Two clients (Flutter + a `curl`-based actor identifying as an "agent") can both edit notes and observe each other's lock and changed events, demonstrating the human + agent shared workspace promise.
- An operator can mint an agent-onboarding invite and an agent (or a `curl`-based stand-in) can bootstrap itself in a single fetch of `onboarding.txt`, then issue authenticated calls against `/notes`.
- A `v0.1.0` (or first-release) tag has been cut by release-please and a multi-arch image is pullable from `ghcr.io/<owner>/robot-notes-server` for both `linux/amd64` and `linux/arm64`.
- Dependabot is enabled and has reported its initial scan with no configuration warnings.
