# release-pipeline Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Repository follows conventional-commits

Every commit landed on the default branch SHALL conform to the conventional-commits specification (`type(scope?): subject`). Allowed types SHALL include at minimum `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `build`, `perf`. Breaking changes SHALL be flagged via a `!` after the type or a `BREAKING CHANGE:` footer.

#### Scenario: Conventional-commits is enforced via tooling

- **WHEN** a commit is made on a developer machine
- **THEN** a configured commit-msg check (e.g. `commitlint` or pre-commit hook) SHALL reject non-conforming messages
- **AND** the same check SHALL run in CI on pull requests, failing the build for non-conforming messages

#### Scenario: Allowed types are documented

- **WHEN** a contributor reads `CONTRIBUTING.md` (or equivalent)
- **THEN** the document SHALL list the accepted commit types and how to indicate breaking changes

### Requirement: release-please manages versions, changelogs, and tags

A `release-please` GitHub Action SHALL run on every push to the default branch. It SHALL maintain a release pull request that, when merged, creates a `vX.Y.Z` tag, a GitHub release, and an updated `CHANGELOG.md`. Configuration SHALL use **manifest mode** so additional release components can be added later without restructuring.

#### Scenario: release-please workflow exists

- **WHEN** the repository contains `.github/workflows/release-please.yml`
- **THEN** it SHALL trigger on `push` to the default branch and SHALL invoke `googleapis/release-please-action` (or a documented equivalent) with `release-type: simple` (or per-package types) and a path to `release-please-config.json`

#### Scenario: Manifest and config files exist at repo root

- **WHEN** the repository is at HEAD
- **THEN** `release-please-config.json` SHALL exist at the repo root and SHALL declare each released package, including the server with `package-name: "robot-notes-server"`
- **AND** `.release-please-manifest.json` SHALL exist at the repo root with an initial entry such as `{ ".": "0.0.0" }` (or a per-component map) so the first run produces a coherent first release

#### Scenario: Merging the release PR creates a tag and release

- **GIVEN** release-please has opened a release PR proposing `0.1.0`
- **WHEN** the PR is merged
- **THEN** the workflow SHALL push a `v0.1.0` tag (or `robot-notes-server-v0.1.0` in manifest mode), update `CHANGELOG.md`, and create a GitHub release with the changelog excerpt as the release notes

#### Scenario: A `feat:` commit on main proposes a minor bump

- **GIVEN** the latest release is `0.1.0`
- **WHEN** a commit `feat: add tags filter` is merged to main
- **THEN** release-please SHALL update its release PR to propose `0.2.0`

#### Scenario: A `fix:` commit on main proposes a patch bump

- **GIVEN** the latest release is `0.2.0`
- **WHEN** a commit `fix: correct conflict response shape` is merged to main
- **THEN** release-please SHALL propose `0.2.1`

#### Scenario: A `feat!:` commit (or BREAKING CHANGE footer) proposes a major bump

- **GIVEN** the latest release is `0.2.1`
- **WHEN** a commit with a breaking marker is merged
- **THEN** release-please SHALL propose `1.0.0` (or `0.3.0` while the manifest version is below 1.0, depending on configuration)

### Requirement: Server image is built from a multi-stage Dockerfile

A `server/Dockerfile` SHALL exist that builds the Dart Frog server in a build stage and produces a minimal runtime image in a final stage. The image SHALL run the server as a non-root user, listen on a configurable port (default 8080), declare a volume for persistent data, and include a HEALTHCHECK that exercises `/healthz`.

#### Scenario: Dockerfile is multi-stage

- **WHEN** the file `server/Dockerfile` is inspected
- **THEN** it SHALL contain at least two `FROM` directives — one named build stage that compiles the Dart server, and one final runtime stage that copies only the produced artifact

#### Scenario: Image runs as a non-root user

- **WHEN** a container started from the image runs `id -u`
- **THEN** the result SHALL NOT be `0`

#### Scenario: Image declares a data volume

- **WHEN** the image metadata is inspected (`docker image inspect`)
- **THEN** the `Volumes` map SHALL include an entry for `/data`

#### Scenario: Image exposes a port

- **WHEN** the image metadata is inspected
- **THEN** the `ExposedPorts` map SHALL include `8080/tcp`

#### Scenario: Image declares a healthcheck

- **WHEN** the image metadata is inspected
- **THEN** the `Healthcheck` SHALL be set such that it exercises the server's `/healthz` endpoint and SHALL have a sensible interval (e.g. 30s) and timeout (e.g. 5s)

#### Scenario: Container reads --api-key or env var

- **WHEN** a container is started with `-e ROBOT_NOTES_API_KEY=rn_x`
- **THEN** the server inside SHALL accept requests bearing that key

- **WHEN** a container is started with `--api-key rn_y` appended to the entrypoint
- **THEN** the server SHALL accept that key (and CLI arg SHALL win over env per the auth spec)

### Requirement: Server image is built and pushed for linux/amd64 and linux/arm64

The release workflow SHALL build and push images for both `linux/amd64` and `linux/arm64` using `docker buildx` with QEMU emulation. The same manifest-list digest SHALL be referenced by every published tag.

#### Scenario: Multi-arch manifest is published

- **WHEN** a release tag is published
- **THEN** `docker manifest inspect ghcr.io/<owner>/robot-notes-server:<tag>` SHALL list both `linux/amd64` and `linux/arm64` manifests under the same digest

### Requirement: Images are published to ghcr.io with a documented tag scheme

Tagged releases (cut by release-please) SHALL push images to `ghcr.io/<owner>/robot-notes-server` with the following tags simultaneously:

- `vX.Y.Z` (immutable per release)
- `X.Y` (rolling minor)
- `X` (rolling major)
- `latest` (rolling)
- `sha-<7-char-commit-sha>` (commit identifier)

Pushes to the default branch (between releases) SHALL produce a preview image tagged `main` and `sha-<7-char-commit-sha>`.

#### Scenario: Release publishes the canonical tag set

- **GIVEN** release-please cuts `v1.2.3` from commit `abcdef0...`
- **WHEN** the publish workflow completes
- **THEN** the registry SHALL contain `:v1.2.3`, `:1.2`, `:1`, `:latest`, and `:sha-abcdef0` all pointing at the same multi-arch digest

#### Scenario: Main builds publish a preview tag

- **WHEN** a non-release commit lands on `main` with SHA `1234567...`
- **THEN** the registry SHALL contain `:main` and `:sha-1234567` pointing at the resulting multi-arch digest
- **AND** the rolling tags `:latest`, `:X`, `:X.Y` SHALL NOT be updated by this preview build

#### Scenario: Tags are immutable across builds

- **GIVEN** `:v1.2.3` has been published once
- **WHEN** a workflow re-runs for the same tag (e.g. operator manually re-dispatches)
- **THEN** the workflow SHALL fail OR no-op, but SHALL NOT overwrite `:v1.2.3` with different content (rely on the registry's immutability or an explicit guard)

### Requirement: Publish workflow uses GITHUB_TOKEN with minimal scopes

The publish workflow SHALL authenticate to `ghcr.io` using `secrets.GITHUB_TOKEN` and SHALL declare the minimum required permissions: `contents: write` (release-please) and `packages: write` (push to ghcr). The workflow SHALL NOT depend on any external personal access token or stored secret for normal operation.

#### Scenario: Workflow declares minimal permissions

- **WHEN** the publish workflow file is inspected
- **THEN** it SHALL include a top-level `permissions:` block listing exactly `contents: write` and `packages: write` (and `id-token: write` only if image signing is added later)

#### Scenario: Login uses the issued GITHUB_TOKEN

- **WHEN** the workflow logs in to ghcr
- **THEN** it SHALL use `docker/login-action` with `username: ${{ github.actor }}` and `password: ${{ secrets.GITHUB_TOKEN }}`

### Requirement: CI runs tests, lint, and format on every pull request

A `ci.yml` workflow SHALL run on every pull request and on pushes to the default branch. It SHALL:

- Set up Dart and Flutter.
- Run `make lint`, `make format` (verifying no diff), and `make test` for both the server and the app.
- Build the server Docker image (without pushing) to validate the Dockerfile on every PR.
- Verify conventional-commits on the PR title or commit messages.

#### Scenario: PR with failing tests is blocked

- **GIVEN** a PR introduces a failing server test
- **WHEN** the CI workflow runs
- **THEN** the workflow SHALL fail and the failure SHALL be reported as a required status check

#### Scenario: PR with format drift is blocked

- **GIVEN** a PR contains code that fails `dart format --set-exit-if-changed .`
- **WHEN** CI runs
- **THEN** the workflow SHALL fail

#### Scenario: PR triggers a Docker build dry-run

- **GIVEN** a PR is open
- **WHEN** the CI workflow runs
- **THEN** the server Docker image SHALL build successfully (with no `--push`), validating the Dockerfile

### Requirement: Dependabot covers Dart pub, Flutter pub, GitHub Actions, and Docker

A `.github/dependabot.yml` SHALL configure four ecosystems with weekly schedules:

- `package-ecosystem: "pub"` directory `/server/`
- `package-ecosystem: "pub"` directory `/app/`
- `package-ecosystem: "github-actions"` directory `/`
- `package-ecosystem: "docker"` directory `/server/`

Updates SHALL be grouped where supported (`groups:` blocks for minor and patch updates per ecosystem) to limit PR noise. Auto-merge SHALL NOT be enabled in v1.

#### Scenario: All four ecosystems are configured

- **WHEN** the file `.github/dependabot.yml` is parsed
- **THEN** the `updates:` array SHALL contain one entry per ecosystem above, each with `schedule.interval: weekly`

#### Scenario: PRs are grouped to limit noise

- **WHEN** dependabot proposes minor or patch updates within an ecosystem in the same week
- **THEN** they SHALL be combined into a single grouped PR per ecosystem

#### Scenario: Major updates are individual PRs

- **WHEN** dependabot proposes a major version bump
- **THEN** it SHALL open a dedicated PR for that update, separate from any grouped PR

### Requirement: Release runbook is documented

A `RELEASING.md` (or a section of `README.md`) SHALL document the human-facing release procedure and one-time setup steps.

#### Scenario: Documented bootstrapping covers ghcr visibility

- **WHEN** a maintainer reads `RELEASING.md`
- **THEN** it SHALL describe the one-time step of setting the ghcr package's visibility to public after the first publish, including the navigation path through GitHub UI

#### Scenario: Documented release procedure

- **WHEN** a maintainer reads `RELEASING.md`
- **THEN** it SHALL describe: how to read release-please's open release PR, when and how to merge it, and what happens automatically afterwards (tag → publish → release notes)

#### Scenario: Documented hotfix procedure

- **WHEN** a maintainer needs to ship a hotfix
- **THEN** the runbook SHALL describe how to: land a `fix:` commit on `main`, let release-please open the patch release PR, and merge to publish

### Requirement: Builds are reproducible from a tagged commit

The published image at `ghcr.io/<owner>/robot-notes-server:vX.Y.Z` SHALL be reproducible from the source tree at the commit pointed to by tag `vX.Y.Z` (or `robot-notes-server-vX.Y.Z` in manifest mode), given the same Dockerfile and base image digest. Base images SHALL be referenced by digest (e.g. `debian:stable-slim@sha256:...`) in the Dockerfile or pinned via dependabot's docker ecosystem.

#### Scenario: Base images are pinned

- **WHEN** `server/Dockerfile` is inspected
- **THEN** every `FROM` directive SHALL pin its base image by digest

#### Scenario: Image labels carry provenance

- **WHEN** the image metadata is inspected
- **THEN** OCI-standard labels SHALL be present: `org.opencontainers.image.source` (repo URL), `org.opencontainers.image.revision` (commit SHA), `org.opencontainers.image.version` (tag), and `org.opencontainers.image.created` (build timestamp)

