## Context

robot-notes is a real-time, multi-platform knowledge management app where humans and AI agents share a workspace. The MVP must produce a working end-to-end skeleton — server, storage, real-time sync, search, and a Flutter client — small enough to ship quickly but shaped so future capabilities (CRDTs, multi-tenancy, permissions) can be layered in without breaking the API.

The proposal locks the high-level shape; this document explains *how* the pieces fit together and the rationale for each load-bearing choice.

The project values:

- "Markdown files on disk" as a first-class property — content must be portable, inspectable, and survive the server.
- API-first — the protocol is the product. Humans (Flutter) and agents (HTTP/MCP/whatever) are equal clients.
- Operational simplicity — one binary, one folder, one key.
- TDD — every requirement has a scenario, every scenario becomes a test (per project rules).

## Goals / Non-Goals

**Goals:**

- A working Dart Frog server that authenticates with a single bearer key and serves notes as markdown files.
- Optimistic concurrency that's correct under concurrent writes, with an honest "single editor at a time" UX layered on top.
- Real-time presence and change broadcasts via WebSocket, scoped to per-note subscriptions.
- Production-grade full-text search (FTS5) without sacrificing the "filesystem is the source of truth" property.
- A Flutter client capable of exercising every server capability.
- An API surface that admits CRDTs, multi-tenancy, and permissions in later changes without redesign.

**Non-Goals:**

- Live multi-cursor editing, OT, or CRDTs (deferred — versioning API is forward-compatible).
- User accounts, sessions, OAuth, password flows, multiple keys.
- Multi-tenancy or per-note ACLs.
- Tags, links, backlinks, graph view, attachments.
- Server clustering / horizontal scale (single-process by design).
- Git-as-storage (compatible but out of scope).

## Decisions

### D1: Dart Frog as the backend framework

**Choice:** Dart Frog.

**Alternatives considered:**

- *Serverpod* — fastest path to "ship today" because it bundles auth, WebSocket streams, and Flutter client codegen. Rejected because it's opinionated about Postgres and would fight a "filesystem is the database" data model. Its auth/codegen value also evaporates when our auth is one line of middleware.
- *Shelf* (raw) — gives complete control but requires hand-rolling routing, WebSocket handling, and middleware. Too much glue for an MVP.

**Rationale:** Dart Frog gives file-based routing, native WebSocket support, and middleware composition without imposing storage choices. It's lean enough that the codebase remains readable end-to-end.

### D2: Filesystem is the source of truth; SQLite is a derived index

**Choice:** Markdown files in `data/content/<id>.md` are canonical. Concurrency state (version) lives in YAML frontmatter. Search index lives in `data/search.db` and is rebuildable from the markdown.

**Alternatives considered:**

- *SQLite as primary store* — fastest to query but breaks the markdown-portability story.
- *Pure filesystem, no DB* — would require rolling our own search; FTS5-quality search is too much work for an MVP.

**Rationale:** The data is portable. Backup is `tar`. Inspection is `cat`. A user (or agent) can drop notes into the folder out-of-band; on next startup the index re-derives. The database returns *only* for the search index, which is acceptable because deleting it is non-destructive.

### D3: In-memory state for locks, presence, and the metadata index

**Choice:** Locks (`Map<id, Lock>`), presence (`Map<connId, Subscriber>`), and the note metadata index (`Map<id, NoteMeta>`) all live in process memory. The metadata index is rebuilt on startup by scanning `data/content/*.md`.

**Alternatives considered:**

- *Persisting locks/presence in SQLite* — adds I/O and a second source of truth for state that's inherently ephemeral.

**Rationale:** Locks should not survive restarts. Presence cannot. The metadata index is a cache. None of these benefit from persistence. Single-process serializes all writes to a given note, removing race-condition concerns.

### D4: Optimistic concurrency via `If-Match: <version>`

**Choice:** Each note has a monotonic integer `version` in its frontmatter. PUT requires `If-Match`. Mismatch returns 409 with the current state; if a different actor holds the lock, returns 423. Version increments by 1 on every successful write.

**Alternatives considered:**

- *Last-write-wins* — silent data loss; rejected.
- *OT/patch streams* — closer to live collab but reinvents OT and locks us into an op model before CRDTs.

**Rationale:** Boring, RESTful, well-understood. The 409 contract is forward-compatible: a future CRDT layer can sit underneath the same endpoints, with `version` representing CRDT state hash or vector clock.

### D5: Soft single-editor lock with TTL + heartbeat

**Choice:** `POST /notes/{id}/lock` acquires a per-note advisory lock with TTL of 60 seconds. Holder must `PUT` to heartbeat (extends TTL). `DELETE` releases. Other actors see the lock state and treat the note as read-only in UI; the server returns 423 if they attempt a PUT.

**State machine:**

```
                ┌──────────────┐
                │  UNLOCKED    │ ← TTL expires; DELETE /lock
                └──────┬───────┘
                       │ POST /lock
                       ▼
                ┌──────────────┐ ── PUT /lock (heartbeat) ──┐
                │   LOCKED     │ ◄──────────────────────────┘
                │  by: actor   │
                │  until: t60  │
                └──────┬───────┘
                       │ DELETE /lock | TTL expires
                       ▼
                  UNLOCKED
```

**Alternatives considered:**

- *No lock, just optimistic concurrency* — concurrent typing produces a stream of 409s; bad UX.
- *Hard lock with no expiry* — orphans on disconnect.

**Rationale:** TTL self-heals on disconnect. Heartbeat lets active editors hold the lock as long as they're typing. 423 is the honest answer to "someone else has the floor."

### D6: WebSocket protocol — JSON envelopes, per-note subscriptions

**Choice:** A single `/ws` endpoint. Client sends a hello with `actor`. Client subscribes per note (or `"*"` for all). Server emits typed events: `presence`, `lock`, `changed`. Content is *not* in `changed` — clients GET the note to fetch the new content. This keeps WS messages small and the HTTP cache canonical.

**Message envelope:**

```json
{ "type": "changed", "note_id": "01HXY...", "version": 6, "by": "alice" }
{ "type": "presence", "note_id": "01HXY...", "viewers": ["alice", "agent-bot"] }
{ "type": "lock", "note_id": "01HXY...", "holder": "alice", "expires_at": "..." }
```

**Alternatives considered:**

- *Server pushes full content in `changed`* — saves a round-trip but inflates messages and duplicates the HTTP source of truth.
- *Server-Sent Events (SSE)* — simpler than WS but one-way; we want bidirectional for hello/subscribe.

**Rationale:** HTTP is the canonical content channel; WS is a notification channel. Clean separation, simpler caching, and the WS protocol stays small.

### D7: Authentication is a single bearer key from `--api-key` / env var

**Choice:** Server takes a key at startup. Every request requires `Authorization: Bearer <key>`; mismatch is 401. CLI arg wins over env var. Rotating the key requires restart.

**Alternatives considered:**

- *Multiple keys with labels in DB* — adds users, revocation, key listing, secret hashing. Real product, not MVP.
- *No auth* — unsafe even for a self-hosted dev tool.

**Rationale:** Smallest auth that works. The trust boundary is the key itself; whoever has it is trusted. Single-tenant means there's no privilege escalation surface.

### D8: Trust-the-client identity via `X-Actor`

**Choice:** Clients self-declare their display name in `X-Actor` (HTTP) or the WebSocket hello. Server uses it for `by` / `holder` / `viewers`. Default to `"unknown"` if absent. Never authenticated.

**Alternatives considered:**

- *Bind identity to the key* — would require multiple keys.
- *No identity at all* — collab UX (lock, presence) becomes meaningless.

**Rationale:** With the key as the trust boundary, lying about your name buys nothing. Identity is for display, not authorization.

### D9: SQLite FTS5 with `package:sqlite3` for search

**Choice:** A single virtual table:

```sql
CREATE VIRTUAL TABLE note_fts USING fts5(
  id UNINDEXED,
  title,
  content,
  tokenize='porter unicode61'
);
```

Updated on every save and delete. Rebuilt from `data/content/*.md` on startup if `search.db` is missing or fails an integrity check.

**Alternatives considered:**

- *`drift`* — overkill for one virtual table and ~5 queries.
- *Roll-your-own inverted index* — months of work to match FTS5 quality (stemming, ranking, snippets).
- *Tantivy via FFI* — adds Rust toolchain.
- *Sidecar (Meilisearch/Typesense)* — defeats single-binary deployment.

**Rationale:** SQLite FTS5 is the only mature embedded FTS in the Dart ecosystem. Treating it as a derived cache preserves the markdown-first ethos.

### D10: ULID identifiers, atomic writes

**Choice:** Note IDs are ULIDs (sortable, opaque). Filenames are `<id>.md`. All writes go through write-tmp + fsync + rename to guarantee no torn files.

**Alternatives considered:** UUIDv4 (not sortable, harder to scan in time order), human-friendly slugs (collision-prone, mutable on rename).

**Rationale:** Sortable IDs let directory scans be implicitly time-ordered. Atomic rename is POSIX-guaranteed; it's the standard way to update a file safely.

### D11: Multi-stage, distroless-style Docker image for the server only

**Choice:** A single multi-stage `server/Dockerfile`. Stage 1 compiles the Dart Frog server to a native AOT binary with `dart compile exe`. Stage 2 is a minimal runtime image (`debian:stable-slim` to keep glibc + `libsqlite3` available, OR `dart:stable-sdk` runtime if AOT and `dart_frog` runtime requirements complicate slim base images). The image:

- Runs as a non-root UID (e.g. 10001).
- Exposes a single port (default 8080).
- Declares `VOLUME /data`.
- Uses an `ENTRYPOINT` that respects `--api-key` / env vars.
- Includes `HEALTHCHECK` invoking `/healthz`.
- Builds for `linux/amd64` and `linux/arm64` via `docker buildx`.

Only the server is containerized. The Flutter app is not published as a Docker image; binaries can be added to releases in a later change.

**Alternatives considered:**

- *`scratch` final stage* — smallest image, but requires statically-linking `libsqlite3` and assuming no glibc. Brittle for an MVP.
- *`alpine` base* — smaller than `debian:slim`, but musl introduces subtle incompatibilities with Dart AOT in some configurations. Not worth the risk for a single-digit MB difference at v1.

**Rationale:** Multi-stage keeps the final image free of build tooling. `debian:stable-slim` is the boring, well-supported choice that just works.

### D12: Conventional commits + release-please for version automation

**Choice:** All commits to `main` follow conventional-commits (per project rules). `release-please` watches `main` and maintains a continuously-updated PR that bumps the version in a `version.txt` (or pubspec) and updates `CHANGELOG.md` based on commit history. Merging that PR cuts a tag like `vX.Y.Z` and creates a GitHub release. Configuration lives in `release-please-config.json` + `.release-please-manifest.json` at the repo root, in **manifest mode** so additional release components (Flutter app, helm chart) can be added later without re-architecting.

**Alternatives considered:**

- *Manual tagging* — fast for v1 but commits drift away from conventional-commits without enforcement, and changelogs rot.
- *`semantic-release`* — npm-ecosystem tool, doesn't fit a Dart-first repo; Google's `release-please` is GitHub-native and language-aware (supports Dart pubspec).
- *`auto`* — similar territory; release-please is preferred because it's the common Google/Anthropic pattern and is well-maintained.

**Rationale:** Release PRs serve as a human review checkpoint between landing commits and publishing artifacts. Manifest mode is forward-compatible.

### D13: ghcr.io for the registry, GITHUB_TOKEN for auth

**Choice:** Images are published to `ghcr.io/<owner>/robot-notes-server`. Authentication uses the `GITHUB_TOKEN` automatically issued to GitHub Actions, with the workflow declaring `permissions: { packages: write, contents: write }`. Initial package visibility SHALL be set to public after the first successful publish (one-time manual action, documented in the runbook).

**Tag strategy:**

```
On every release-please tag vX.Y.Z:
  ghcr.io/<owner>/robot-notes-server:vX.Y.Z   (immutable)
  ghcr.io/<owner>/robot-notes-server:X.Y      (rolling minor)
  ghcr.io/<owner>/robot-notes-server:X        (rolling major)
  ghcr.io/<owner>/robot-notes-server:latest   (rolling)
  ghcr.io/<owner>/robot-notes-server:sha-<7>  (commit SHA)

On every main commit (preview build):
  ghcr.io/<owner>/robot-notes-server:main
  ghcr.io/<owner>/robot-notes-server:sha-<7>
```

**Alternatives considered:**

- *Docker Hub* — requires a separate account + secret; `GITHUB_TOKEN` works for ghcr without configuration.
- *Self-hosted registry* — more ops surface than the MVP needs.

**Rationale:** ghcr is free, integrates with the same `GITHUB_TOKEN` already powering the rest of CI, and inherits repo-level access controls.

### D14: Dependabot for Dart pub, Flutter pub, GitHub Actions, and Docker

**Choice:** A single `.github/dependabot.yml` configures four ecosystems:

- `pub` for `server/` (server Dart packages)
- `pub` for `app/` (Flutter packages)
- `github-actions` for `.github/workflows/`
- `docker` for `server/` (base image updates)

Schedule: weekly. Major-version updates produce one PR per package. Updates are grouped by minor/patch where supported, to limit PR noise.

**Rationale:** Keeps the four moving surfaces of the project — backend, app, CI, base image — current without manual chasing. Weekly cadence balances freshness with review cost. Auto-merge is **not** enabled in v1; humans review.

### D15: Agent self-onboarding via single-use invite URLs

**Choice:** The operator (i.e. anyone holding the API key) mints a single-use, time-limited invite URL via `POST /invites`. The agent fetches `GET /invites/{token}/onboarding.txt` once — that fetch returns the base URL, the shared bearer key, a recommended `X-Actor` value, and an inline guide to the API — and the invite is then burned. Invites are stored as JSON files at `data/invites/<token>.json`, listed via `GET /invites`, and revoked by `DELETE /invites/{token}` (which deletes the file).

**Endpoints:**

```
POST   /invites              (Bearer)  body: { label?, ttl_seconds? }   → { token, url, expires_at, single_use: true }
GET    /invites              (Bearer)                                    → list active invites
DELETE /invites/{token}      (Bearer)                                    → 204 (revokes)
GET    /invites/{token}/onboarding.txt   (no auth)                       → text/plain bundle, single-use
```

**Onboarding bundle (text/plain):** a short intro, the base URL, the shared API key, recommended `X-Actor` (defaulting to the invite label), a verification step (`curl -H "Authorization: Bearer ..." .../healthz`), and an inline reference to the API surface (endpoints, lock semantics, WS protocol). One fetch, one bundle, no follow-up calls.

**Lifecycle:**

- Default TTL: 24 hours; max: 30 days.
- Single-use: the first successful `GET .../onboarding.txt` writes a `burned_at` timestamp into the JSON; subsequent fetches return 410 Gone.
- Expiration: missing or expired tokens return 404.
- Revocation: deleting the JSON file revokes immediately.

**Alternatives considered:**

- *A separate per-agent token system* — would require a token database, hashing, scopes, and revocation lists. Defeats the "one bearer key, single-tenant" trust boundary the project deliberately chose.
- *Static onboarding URL with the key in the path* — bookmarkable / cacheable / leakable forever. Single-use TTL is a strict improvement.
- *Manual copy-paste of the key* — works but doesn't help the LLM-onboarding-from-a-UI-button use case the feature is for.

**Rationale:** KISS. The feature exists to hand an LLM "everything it needs in one fetch" without inventing a parallel auth model. Because the bundle ships the same shared key, the invite URL has the same security level as the key itself — single-use + short TTL + secure-channel distribution (HTTPS, copy-paste in a trusted UI) keeps the blast radius small. Revocation of one agent's onboarding URL doesn't affect anyone else; the file just goes away.

### D16: Forward compatibility for CRDTs and multi-tenancy

The API shape is chosen so future capabilities don't break it:

- Adding CRDT operations is a new endpoint (`POST /notes/{id}/ops`) and a new WS event type. Existing PUT semantics continue to work.
- Multi-tenancy adds a `/workspaces/{ws}` prefix or `Workspace:` header without changing per-note routes.
- Per-note permissions become an additional 403 response on existing endpoints.

We do not need to design those today, only avoid choices that preclude them. The chosen design does not preclude any of them.

## Risks / Trade-offs

- **[Risk] Frontmatter version drifts from filesystem reality** (e.g., manual edit) → **Mitigation:** On startup, the index re-derives from frontmatter. Mid-session, all writes go through the server. Out-of-band edits during a session aren't supported in v1; document it.

- **[Risk] FTS index drift after server crash mid-write** → **Mitigation:** On startup, run `PRAGMA integrity_check`; on any failure, drop and rebuild. Periodic background reconciliation can be added later.

- **[Risk] In-memory locks lost on restart leave clients with stale UI** → **Mitigation:** Acceptable. Clients re-subscribe on reconnect and receive fresh `lock` events (or absence of them). Document that restart is a hard reset for ephemeral state.

- **[Risk] Single-process bottleneck for many concurrent writers** → **Mitigation:** Single-tenant assumption. If concurrency becomes a problem, that's the signal to revisit at a later change, not now.

- **[Risk] `--api-key` visible in `ps aux`** → **Mitigation:** Support `ROBOT_NOTES_API_KEY` env var and document that env is preferred for non-dev deploys.

- **[Risk] SQLite native lib distribution friction** → **Mitigation:** Use `sqlite3_native_assets` to bundle; fall back to system `libsqlite3` if not available.

- **[Risk] Trust-the-client identity is lying-friendly** → **Mitigation:** Single-tenant trust boundary is the key. Any actor with the key can already do anything; identity is purely cosmetic. Documented explicitly.

- **[Trade-off] No live keystroke sync in v1** → Acceptable; the lock + version-bump model is honest about that. CRDTs come later under a separate change.

- **[Trade-off] No history beyond current `version`** → Git-as-storage could be added later non-invasively; out of scope for now.

- **[Risk] Multi-arch build slow / flaky on GitHub-hosted runners** (`linux/arm64` via QEMU) → **Mitigation:** Use `docker/setup-qemu-action` + `docker/setup-buildx-action`. Document expected ~15-min build for v1. Consider native arm64 runners if/when available.

- **[Risk] First publish to ghcr fails because the package is private/unconfigured** → **Mitigation:** Document the one-time post-publish step (Settings → Packages → set visibility to public, link to repo). Include this in the release runbook.

- **[Risk] release-please opens a confusing first-release PR with no prior tag** → **Mitigation:** Initial commit message follows conventional commits. Document that the *very first* version emerges as `0.1.0` after merging the bootstrap release PR. The `.release-please-manifest.json` is initialized to `{ ".": "0.0.0" }` so the first run does the right thing.

- **[Risk] Dependabot churn drowns out human PRs** → **Mitigation:** Group minor/patch updates per ecosystem, weekly schedule, no auto-merge. Revisit if the volume becomes a problem.

- **[Trade-off] Not signing images / publishing SBOM in v1** → Acceptable. Image is built reproducibly by GitHub Actions from a pinned commit and tagged immutably with the SHA. A later change can layer cosign + sigstore + SBOMs.

- **[Risk] Invite URL leaks expose the shared API key** → **Mitigation:** invites are single-use (burn on first fetch), short-TTL (24h default, 30d max), and revocable by deleting the file. The bundle SHALL only be served over the same channel as the rest of the API (HTTPS in production), and the operator SHALL be reminded in `RELEASING.md` that an invite URL is as sensitive as the bearer key itself.

- **[Trade-off] Invites hand out the same shared key to every agent** → Accepted. A per-agent token model is a future change (`scoped-tokens` capability); v1 keeps the trust boundary at one key and uses identity (`X-Actor`) only for display. If one agent misbehaves, the only remediation is rotating the server key (restart) — documented.

## Migration Plan

This is the inaugural change — no migration. Bootstrapping order:

1. Repository layout: top-level `server/` (Dart Frog) and `app/` (Flutter) workspaces. Shared DTO package optional but recommended.
2. Server first to a passing health check; then auth middleware; then storage; then API; then locks; then WS; then search.
3. Flutter client follows once the server has a stable enough surface to consume.

No rollback path required — there is no prior version to roll back to.

## Open Questions

- **Repository structure:** mono-repo with `server/` and `app/` siblings vs. separate repos? Recommend mono-repo for MVP; revisit if release cadences diverge.
- **Frontmatter parser:** `package:yaml` vs. a hand-rolled minimal parser? Recommend `package:yaml` for correctness; the cost is small.
- **WebSocket auth:** does the Bearer key go in a query parameter (Sec-WebSocket-Protocol works but is awkward), an Authorization header (some browsers strip), or as the first message after connect? **Recommendation:** require key in the first WS message (auth frame); reject the connection if not received within ~2 seconds.
- **Pagination scheme on `GET /notes`:** cursor (sortable ULIDs make this trivial) vs. offset/limit. Recommend cursor.
- **Snippet length / highlight markers** for `/search` — pick reasonable defaults; document them in the search spec.
- **Owner / org for ghcr publish:** depends on the actual GitHub repository owner. The workflow SHALL derive it from `${{ github.repository_owner }}` so it works for any fork or migration without manual edits.
- **Dart Frog runtime requirements in the final image:** confirm whether `dart:stable` or `debian:stable-slim` is the right base by trying both during implementation. The spec lets either be chosen as long as the resulting image satisfies the size and security requirements.
- **Flutter binary releases:** out of scope for v1, but at least one user will eventually want a Linux desktop binary. Track it as a follow-on change rather than expanding scope here.
