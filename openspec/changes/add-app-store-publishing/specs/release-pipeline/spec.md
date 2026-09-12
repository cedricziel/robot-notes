## ADDED Requirements

### Requirement: Releases publish the client to TestFlight

The release workflow SHALL build the Flutter client for iOS and macOS from the release tag, sign it with App Store distribution credentials obtained through `fastlane match`, and upload the binaries to TestFlight for internal testers. The two platforms SHALL run as independent jobs so one failing does not block the other or the container publish.

#### Scenario: Apple jobs run on every release

- **GIVEN** `resolve-tag` produced a tag (from release-please or a `workflow_dispatch` input)
- **WHEN** the workflow runs
- **THEN** an `apple` job SHALL run once for `ios` and once for `macos` on a macOS runner, checking out that tag

#### Scenario: Version and build number derive from the tag

- **GIVEN** the tag `vX.Y.Z` points at a commit with `N` reachable commits
- **WHEN** the Apple job builds
- **THEN** the binary's marketing version SHALL be `X.Y.Z` and its build number SHALL be `N`

#### Scenario: Binary is uploaded to TestFlight

- **WHEN** the build succeeds
- **THEN** the job SHALL upload the IPA (iOS) or PKG (macOS) to TestFlight, wait for App Store Connect to finish processing it, and set the GitHub release body as the build's changelog
- **AND** the build SHALL NOT be submitted for App Store review by this path

### Requirement: Promoting a pre-release submits its build to App Store review

The release workflow SHALL also trigger on `release` events of type `released`. For each platform it SHALL then attach that tag's TestFlight build (identified by the tag's marketing version and commit-count build number) to the App Store version, upload the listing metadata in `app/fastlane/metadata` with the GitHub release body as release notes, submit the version for review, and enable automatic release after approval. This path SHALL NOT rebuild or re-upload a binary, and SHALL NOT run the container image jobs.

#### Scenario: Promotion runs only the submit path

- **GIVEN** the pre-release `vX.Y.Z` is edited to a full release ("Set as the latest release")
- **WHEN** the workflow runs on the resulting `released` event
- **THEN** release-please, the web bundle, and the image build and manifest jobs SHALL be skipped
- **AND** the `apple` jobs SHALL NOT install Flutter, run match, or archive, and SHALL run the platform's `submit_to_app_store` lane with `version: X.Y.Z`

#### Scenario: Cutting a release never submits

- **WHEN** release-please cuts a release and the workflow publishes it as a pre-release
- **THEN** no `released` event SHALL fire and no App Store submission SHALL happen until a human promotes the release

#### Scenario: Missing TestFlight build fails the submit

- **GIVEN** no processed build with the tag's version and build number exists in App Store Connect
- **WHEN** the submit path runs
- **THEN** the job SHALL fail without creating or altering a submission

#### Scenario: Artifact is retained

- **WHEN** an Apple job finishes, successfully or not
- **THEN** any produced IPA or PKG SHALL be uploaded as a workflow artifact retained for 30 days

### Requirement: App Store signing state lives outside the repository

Signing certificates and provisioning profiles SHALL be stored encrypted in the private `cedricziel/certificates` repository managed by `fastlane match`. The workflow SHALL access that repository over a read-only deploy key and SHALL never create or modify signing assets (`readonly: true` in CI). Regenerating profiles SHALL be a documented local operation.

#### Scenario: CI cannot mutate signing assets

- **WHEN** the Apple job runs `match`
- **THEN** it SHALL run in read-only mode, and a missing profile SHALL fail the job rather than create one

#### Scenario: Secrets are inventoried

- **WHEN** a maintainer reads `RELEASING.md`
- **THEN** it SHALL list every repository secret the Apple jobs need and where each value is kept

### Requirement: App Store listing is versioned in the repository

Listing text, category, age rating, and review contact information SHALL live under `app/fastlane` and be uploaded by the pipeline. The privacy policy the listing links to SHALL be `PRIVACY.md` at the repository root. Screenshots and the App Privacy questionnaire are out of scope and are maintained by hand in App Store Connect.

#### Scenario: Metadata is uploaded with every release

- **WHEN** an Apple job uploads a binary
- **THEN** it SHALL also upload the metadata under `app/fastlane/metadata`, skipping screenshots

## MODIFIED Requirements

### Requirement: release-please manages versions, changelogs, and tags

A `release-please` GitHub Action SHALL run on every push to the default branch. It SHALL maintain a release pull request that, when merged, creates a `vX.Y.Z` tag, a GitHub release, and an updated `CHANGELOG.md`. Configuration SHALL use **manifest mode** so additional release components can be added later without restructuring. The release SHALL be created as a draft (`"draft": true`) and published by the workflow as a **pre-release** using `GITHUB_TOKEN`, so that creating a release never fires a `released` event; promoting it to a full release is a human action.

#### Scenario: release-please workflow exists

- **WHEN** the repository contains `.github/workflows/release-please.yml`
- **THEN** it SHALL trigger on `push` to the default branch and SHALL invoke `googleapis/release-please-action` (or a documented equivalent) with `release-type: simple` (or per-package types) and a path to `release-please-config.json`

#### Scenario: Manifest and config files exist at repo root

- **WHEN** the repository is at HEAD
- **THEN** `release-please-config.json` SHALL exist at the repo root and SHALL declare each released package, including the server with `package-name: "robot-notes-server"`, and SHALL set `"draft": true`
- **AND** `.release-please-manifest.json` SHALL exist at the repo root with an initial entry such as `{ ".": "0.0.0" }` (or a per-component map) so the first run produces a coherent first release

#### Scenario: Merging the release PR creates a tag and release

- **GIVEN** release-please has opened a release PR proposing `0.1.0`
- **WHEN** the PR is merged
- **THEN** the workflow SHALL push a `v0.1.0` tag, update `CHANGELOG.md`, and leave a GitHub release marked as a pre-release with the changelog excerpt as the release notes

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

### Requirement: Publish workflow uses GITHUB_TOKEN with minimal scopes

The container publish jobs SHALL authenticate to `ghcr.io` using `secrets.GITHUB_TOKEN` and SHALL declare the minimum required permissions (`contents: read`, `packages: write`). The container jobs SHALL NOT depend on any external personal access token or stored secret for normal operation. The Apple jobs are the exception: they SHALL use the dedicated App Store Connect and match secrets listed in `RELEASING.md`, and SHALL declare only `contents: read`.

#### Scenario: Workflow declares minimal permissions

- **WHEN** the publish workflow file is inspected
- **THEN** the top-level `permissions:` block SHALL grant only `contents: read`, and each job SHALL elevate only what it needs (`contents: write` and `pull-requests: write` for release-please, `packages: write` for image pushes)

#### Scenario: Login uses the issued GITHUB_TOKEN

- **WHEN** the workflow logs in to ghcr
- **THEN** it SHALL use `docker/login-action` with `username: ${{ github.actor }}` and `password: ${{ secrets.GITHUB_TOKEN }}`

#### Scenario: Apple jobs use only their own secrets

- **WHEN** the `apple` job is inspected
- **THEN** it SHALL reference only `ASC_*` and `MATCH_*` secrets plus `GITHUB_TOKEN` for reading the release body, and SHALL NOT reference `RELEASE_PLEASE_TOKEN`

### Requirement: Dependabot covers Dart pub, Flutter pub, GitHub Actions, Docker, and Bundler

A `.github/dependabot.yml` SHALL configure these ecosystems with daily schedules:

- `package-ecosystem: "pub"` directory `/` (workspace root)
- `package-ecosystem: "github-actions"` directory `/`
- `package-ecosystem: "docker"` directory `/server`
- `package-ecosystem: "bundler"` directory `/app`

Updates SHALL be grouped where supported (`groups:` blocks for minor and patch updates per ecosystem) to limit PR noise. Auto-merge SHALL NOT be enabled in v1.

#### Scenario: All ecosystems are configured

- **WHEN** the file `.github/dependabot.yml` is parsed
- **THEN** the `updates:` array SHALL contain one entry per ecosystem above

#### Scenario: PRs are grouped to limit noise

- **WHEN** dependabot proposes minor or patch updates within an ecosystem in the same period
- **THEN** they SHALL be combined into a single grouped PR per ecosystem

#### Scenario: Major updates are individual PRs

- **WHEN** dependabot proposes a major version bump
- **THEN** it SHALL open a dedicated PR for that update, separate from any grouped PR
