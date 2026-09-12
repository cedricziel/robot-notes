# robot-notes

Real-time knowledge management for humans **and** AI agents. The filesystem
is the database — every note lives as a markdown file with YAML frontmatter
on disk, indexed by SQLite FTS5 and broadcast over a WebSocket.

> Status: bootstrapping the MVP foundation. See
> `openspec/changes/add-mvp-foundation/` for the active proposal, design,
> specs, and task list.

## Layout

This repo is a single Dart pub workspace.

| Package   | Kind      | Purpose                                                              |
| --------- | --------- | -------------------------------------------------------------------- |
| `shared/` | pure Dart | API-contract DTOs, WS envelopes, error codes, route constants        |
| `server/` | Dart Frog | HTTP + WebSocket server, atomic markdown storage, FTS5 search, locks |
| `app/`    | Flutter   | Multi-platform client (mobile, desktop, web)                         |

## Quickstart

Requirements: Dart `^3.6.0`, Flutter `>=3.27.0` (3.41 recommended — that's
what CI runs against and what bundles Dart 3.11).

```sh
# Install workspace deps + the pre-commit hook
make install
make hooks

# Run the suites
make test

# Start the server (Dart Frog dev mode)
make run-server

# Start the Flutter client
make run-app
```

### Running the server

Pick **one** mechanism for the API key — the CLI flag wins over the env var:

```sh
# Env var (preferred for shells and Docker):
export ROBOT_NOTES_API_KEY=rn_your_secret
make run-server

# Or pass it as a CLI flag (handy in launchctl/systemd unit files):
cd server && dart_frog dev -- --api-key rn_your_secret --data-dir ./data
```

Other knobs (with their env equivalents):

| Flag           | Env var                  | Default      | What it controls                                                                                                                                                                                                                                             |
| -------------- | ------------------------ | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--api-key`    | `ROBOT_NOTES_API_KEY`    | _(required)_ | Bearer token for every request.                                                                                                                                                                                                                              |
| `--data-dir`   | `ROBOT_NOTES_DATA_DIR`   | `./data`     | Root for `content/`, `invites/`, `oauth/`, `search.db`.                                                                                                                                                                                                      |
| `--port`       | `ROBOT_NOTES_PORT`       | `8080`       | Listen port.                                                                                                                                                                                                                                                 |
| `--web-dir`    | `ROBOT_NOTES_WEB_DIR`    | _(unset)_    | When set, serve a Flutter web bundle at `/`. The published Docker image sets this automatically.                                                                                                                                                             |
| `--public-url` | `ROBOT_NOTES_PUBLIC_URL` | _(unset)_    | Absolute origin (scheme + host + optional port, no path) used in OAuth metadata, invite URLs, and MCP resource identifiers. Recommended whenever the server sits behind a reverse proxy; otherwise it's derived per request from `X-Forwarded-Proto`/`Host`. |

Every HTTP request must carry `Authorization: Bearer <key>`. Clients
self-declare their display name with the `X-Actor: <name>` header (defaulting
to `unknown` when absent).

### Pointing the Flutter app at a server

The app reads its base URL, API key, and actor identity at startup. Pass them
in via `--dart-define` (handy for both `flutter run` and `flutter build`):

```sh
flutter run \
  --dart-define=ROBOT_NOTES_BASE_URL=http://127.0.0.1:8080 \
  --dart-define=ROBOT_NOTES_API_KEY=rn_your_secret \
  --dart-define=ROBOT_NOTES_ACTOR=cedric
```

For desktop/release builds bake those values into the bundle the same way:

```sh
flutter build macos \
  --dart-define=ROBOT_NOTES_BASE_URL=https://notes.example.com \
  --dart-define=ROBOT_NOTES_API_KEY=rn_your_secret \
  --dart-define=ROBOT_NOTES_ACTOR=cedric
```

### Running the server via Docker

The CI pipeline publishes a multi-arch (`linux/amd64`, `linux/arm64`)
container image for every release at `ghcr.io/<owner>/robot-notes-server`:

```sh
docker run --rm \
  -e ROBOT_NOTES_API_KEY=rn_your_secret \
  -e ROBOT_NOTES_PUBLIC_URL=https://notes.example.com \
  -v "$(pwd)/data:/data" \
  -p 8080:8080 \
  ghcr.io/<owner>/robot-notes-server:latest
```

Set `ROBOT_NOTES_PUBLIC_URL` whenever the container sits behind a reverse
proxy or a different externally visible host/port than the one it binds
to — it pins the origin used in OAuth metadata, invite URLs, and the MCP
resource identifier instead of trusting `X-Forwarded-Proto`/`Host` on
each request.

The image is plug-and-play: open `http://localhost:8080/` in a browser
and the bundled Flutter web UI loads. The setup screen pre-fills the
server URL with the current origin, so the user only enters the API key
and a display name. The same image continues to serve the JSON/WebSocket
API at the documented paths — `/notes`, `/search`, `/invites`,
`/healthz`, `/ws`, etc. — and gates everything except `/healthz`,
`/ws`, the onboarding bundle, and the static SPA assets behind the
configured bearer key.

The image runs as UID 10001, exposes port 8080, declares `/data` as a
VOLUME, and ships an HTTP `HEALTHCHECK` against `/healthz`. To pin to a
specific release use `:vX.Y.Z` (or `@sha256:…` for hard immutability).

Local dev build of the same image:

```sh
make docker-build
```

### Deploying as a TrueNAS SCALE Custom App

TrueNAS SCALE's "Custom App" install path (the `ix-app` catalog entry)
runs the same image as a single Docker container instead of a Compose
stack. There's no wizard field for a bind-mounted host path or an
environment variable list from the CLI, so if you're driving this via
the `middleware` API (`app.create` / `app.update`), the `values`
payload needs this shape:

```jsonc
{
  "image": {
    "repository": "ghcr.io/<owner>/robot-notes-server",
    "tag": "main",
  },
  "envs": [{ "name": "ROBOT_NOTES_API_KEY", "value": "rn_your_secret" }],
  "ports": [
    { "container_port": 8080, "port_number": 30300, "protocol": "tcp" },
  ],
  "storage": [
    {
      "type": "host_path",
      "host_path_config": { "path": "/mnt/<pool>/apps/robot-notes/data" },
      "mount_path": "/data",
    },
  ],
  "restart_policy": "unless-stopped",
}
```

Notes:

- The host path in `storage[].host_path_config.path` must already
  exist (`filesystem.mkdir`) before `app.create`/`app.update` will
  accept it, and should be owned by UID/GID `10001` (`filesystem.setperm`)
  to match the image's non-root user.
- `port_number` is the **host** port; `container_port` (`8080`) is
  fixed by the image.
- See the [tag scheme](RELEASING.md#tag-scheme) for what `:main` vs.
  `:vX.Y.Z` means — `main` is hand-pushed, not CI-built, so re-push it
  before relying on it for a fresh deployment.

### Onboarding an agent

Agents bootstrap themselves with one HTTPS fetch. The operator mints a
single-use invite, hands the URL to the agent, and the agent reads the
`onboarding.txt` bundle that contains the API base URL, an actor name, and
the API key it should use:

```sh
# Operator mints the invite (authenticated as the bearer-key holder):
curl -X POST https://notes.example.com/invites \
     -H "Authorization: Bearer $ROBOT_NOTES_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"label": "research-bot", "ttl_seconds": 3600}'

# → 201 Created with { "url": "https://.../invites/<token>/onboarding.txt", … }
# Share that URL with the agent over a confidential channel.

# Agent fetches once (no auth header — the URL itself IS the credential):
curl https://notes.example.com/invites/<token>/onboarding.txt
# → bundle is consumed; second fetch returns 410.
```

The invite URL is bearer-equivalent: treat it like a credential, share it
over an encrypted channel, and revoke proactively if you suspect leakage
(`DELETE /invites/<token>`). Full lifecycle is in
[`RELEASING.md`](RELEASING.md#operating-agent-onboarding-invites) and the
spec at
`openspec/changes/add-mvp-foundation/specs/agent-onboarding/spec.md`.

### Connecting an MCP client

The server exposes the note workspace as a stateless MCP (Streamable
HTTP) endpoint at `<base>/mcp`, e.g. `https://notes.example.com/mcp`.

Most hosted or desktop MCP clients only need that one URL: they discover
the OAuth endpoints automatically from
`/.well-known/oauth-protected-resource` and
`/.well-known/oauth-authorization-server`, register themselves via
Dynamic Client Registration (`POST /oauth/register`), and open a browser
consent page. That page asks the person completing setup for the
workspace API key (proof they're allowed to grant access) and a display
name — the actor every note the agent writes will be attributed to.
Approving the page redirects the client back with an authorization
code, which it exchanges at `POST /oauth/token` for an access token
scoped to `notes:read` and/or `notes:write`.

Agents that already hold the static key — for example ones onboarded
through the invite flow described above — can skip OAuth entirely and
call `/mcp` the same way they call the rest of the API:

```
Authorization: Bearer <api-key>
X-Actor: <name>
```

Both credentials are accepted on the same endpoint, so the two
onboarding paths coexist.

A handful of responses are specific to `/mcp`: an unauthenticated
`GET` or `DELETE` is `401` rather than `405` (the credential is
checked before the method), a request whose `Origin` header does not
match the server's own origin (or a loopback origin) is `403
forbidden`, and a request naming an `MCP-Protocol-Version` this server
does not understand is `400 unsupported_protocol_version`.

The tool catalog is fixed and identical for every caller:

| Tool             | What it does                                                                    |
| ---------------- | ------------------------------------------------------------------------------- |
| `list_notes`     | Paginated note metadata (id, title, version, timestamps) — no content.          |
| `get_note`       | Fetch one note's full content by id, including lock status.                     |
| `search_notes`   | Full-text search over titles and content, ranked, with `<mark>` snippets.       |
| `create_note`    | Create a note with a title and optional content.                                |
| `update_note`    | Update a note, enforcing the note's current `version` (optimistic concurrency). |
| `append_to_note` | Append text to a note's end without a read-modify-write race.                   |
| `delete_note`    | Permanently delete a note by id.                                                |

An OAuth grant's scopes gate the write tools (`create_note`,
`update_note`, `append_to_note`, `delete_note`) separately from the read
tools; the static key always holds both scopes.

**Security:** run the server behind HTTPS in any deployment reachable
over an untrusted network — the consent form submits the workspace API
key over that connection, with the same exposure as the bearer check
everywhere else in the API. See `--public-url` above for pinning the
origin OAuth metadata advertises when the server sits behind a proxy.

## Conventions

- **TDD**: every requirement has a scenario; every scenario gets a failing
  test before code (`shared/test/`, `server/test/`, `app/test/`).
- **Conventional commits** (`feat:`, `fix:`, `build:`, `docs:`, …) — release-
  please consumes them to cut versions automatically.
- **Pre-commit**: `dart_pre_commit` runs format, analyze, flutter-compat,
  outdated, and pull-up-dependencies against staged files. Install with
  `make hooks` after the first clone.
- **Atomic commits**: one commit per logical change.

See `CONTRIBUTING.md` for the full developer onboarding flow.

## License

Apache 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
