## Why

robot-notes does not exist yet. To make any further progress — features, agent integration, polish — we need a working end-to-end skeleton: a Dart Frog server that authenticates a request, persists a markdown note, indexes it for search, broadcasts a real-time event, and is consumable by a Flutter client. This change establishes that foundation with the smallest set of decisions that still produces a useful product.

## What Changes

- **NEW** Dart Frog backend serving an HTTP + WebSocket API
- **NEW** Note CRUD with optimistic concurrency (`If-Match: <version>`)
- **NEW** Markdown-on-disk storage at `data/content/<id>.md` with YAML frontmatter; the filesystem is the canonical store
- **NEW** Per-note soft editor lock (in-memory, TTL-based, heartbeated)
- **NEW** WebSocket `/ws` endpoint for presence, lock state, and version-bump notifications
- **NEW** SQLite FTS5 search index at `data/search.db`, treated as a derived/rebuildable cache (rebuilt on startup if missing/corrupt)
- **NEW** Single bearer API key auth via `--api-key` CLI argument or `ROBOT_NOTES_API_KEY` env var
- **NEW** Trust-the-client actor identity via `X-Actor` HTTP header / WebSocket hello
- **NEW** Flutter client scaffold capable of listing, reading, editing, locking, and searching notes against the API
- **NEW** Single-tenant deployment model — one server process equals one workspace
- **NEW** Multi-arch (`linux/amd64` + `linux/arm64`) Docker image of the server binary built and published to GitHub Container Registry (`ghcr.io`)
- **NEW** Conventional-commits driven release automation via `release-please` producing signed, semver-tagged GitHub releases
- **NEW** GitHub Actions CI publishing tagged release images to `ghcr.io` and pushing `:latest` + immutable `:vX.Y.Z` + commit-SHA tags
- **NEW** Dependabot configuration covering Dart pub (server), Flutter pub (app), GitHub Actions, and Docker base images
- **NEW** Single-use, time-limited invite URLs that hand an LLM/agent everything it needs to onboard itself in one fetch — base URL, the shared API key, recommended `X-Actor`, and an inline API guide — without inventing a parallel token system

## Capabilities

### New Capabilities

- `auth`: Single bearer-key authentication and trust-the-client actor identity
- `notes-storage`: Filesystem-based markdown storage with frontmatter, atomic writes, and in-memory metadata index
- `notes-api`: HTTP CRUD endpoints with optimistic concurrency
- `lock-management`: Soft single-editor locks with TTL and heartbeat
- `realtime-sync`: WebSocket subscription protocol for presence, lock, and change events
- `search`: SQLite FTS5 derived index over note content with rebuild-on-startup
- `flutter-client`: Multi-platform Flutter client consuming the API and WebSocket
- `release-pipeline`: Versioning, Docker image build, release-please automation, ghcr publish, and dependabot dependency hygiene
- `agent-onboarding`: Operator-minted, single-use invite URLs that bootstrap an agent with credentials and an inline API guide

### Modified Capabilities

None — this is the inaugural change.

## Non-goals

- CRDTs and live multi-cursor editing (deferred; the versioning API is forward-compatible)
- Multi-tenancy, workspaces, organizations
- User accounts, sessions, OAuth, password flows, multiple keys, key revocation
- Permissions, ACLs, per-note ownership
- Tags, links, backlinks, graph view
- Git-as-storage (compatible with the chosen layout, can be added later)
- File attachments, images, embedded media
- Mobile-platform-specific features beyond Flutter defaults
- Server-side full edit history beyond what frontmatter `version` records
- Server clustering / horizontal scaling
- Flutter app binaries published as a release artifact (only the server image is published in v1)
- Helm charts, Kubernetes manifests, or other deployment scaffolding beyond the published Docker image
- Image signing (cosign / sigstore) and SBOM publication (deferred — image is built reproducibly and tagged immutably, signing can be layered later)

## Impact

- **New repository structure**: a single Dart pub workspace at the repo root with three member packages — `server/` (Dart Frog), `app/` (Flutter), and `shared/` (the API-contract package: DTOs, WebSocket envelopes, error codes, route constants — depended on by both `server/` and `app/`)
- **Dependencies**: `dart_frog`, `package:sqlite3`, `package:yaml` (or equivalent frontmatter parser), `package:ulid`, `shelf_web_socket`; on the Flutter side, an HTTP client and WebSocket client
- **Native binary**: SQLite (bundled via `sqlite3_native_assets` or system lib)
- **Operational**: single binary + a `data/` directory (containing `content/`, `search.db`, and `invites/`); rotating the API key requires a server restart; revoking a single agent invite is just deleting its file under `data/invites/`
- **CI/CD surface**: introduces `.github/workflows/` (test, build, release-please, publish), `.github/dependabot.yml`, `release-please-config.json`, `.release-please-manifest.json`, a multi-stage `server/Dockerfile`, and the `ghcr.io/<org>/robot-notes-server` repository
- **GitHub permissions**: workflows require `packages: write` to push to ghcr and `contents: write` for release-please to manage release PRs and tags
- **Forward compatibility**: API surface is shaped to admit CRDT operations and multi-actor permissions in a later change without breaking existing endpoints; release-please configuration is structured so additional packages (Flutter app, helm chart) can be added later as separate components
