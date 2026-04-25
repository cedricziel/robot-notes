# robot-notes

Real-time knowledge management for humans **and** AI agents. The filesystem
is the database — every note lives as a markdown file with YAML frontmatter
on disk, indexed by SQLite FTS5 and broadcast over a WebSocket.

> Status: bootstrapping the MVP foundation. See
> `openspec/changes/add-mvp-foundation/` for the active proposal, design,
> specs, and task list.

## Layout

This repo is a single Dart pub workspace.

| Package    | Kind        | Purpose                                                                  |
| ---------- | ----------- | ------------------------------------------------------------------------ |
| `shared/`  | pure Dart   | API-contract DTOs, WS envelopes, error codes, route constants            |
| `server/`  | Dart Frog   | HTTP + WebSocket server, atomic markdown storage, FTS5 search, locks     |
| `app/`     | Flutter     | Multi-platform client (mobile, desktop, web)                             |

## Quickstart

Requirements: Dart `^3.6.0`, Flutter `>=3.24.0`.

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

The server expects an API key at startup:

```sh
export ROBOT_NOTES_API_KEY=rn_your_secret
make run-server
# or:
cd server && dart_frog dev -- --api-key rn_your_secret --data-dir ./data
```

Every HTTP request must carry `Authorization: Bearer rn_your_secret`. Clients
self-declare their display name with the `X-Actor: <name>` header (defaulting
to `unknown` when absent). The same key onboards agents through single-use
invite URLs minted at `POST /invites` — see
`openspec/changes/add-mvp-foundation/specs/agent-onboarding/spec.md`.

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
