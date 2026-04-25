# Releasing robot-notes

This is the operator runbook for cutting a release, verifying it, and
keeping the supply chain healthy. The mechanical work is done by
[release-please](https://github.com/googleapis/release-please) +
GitHub Actions; humans only review and merge.

---

## Tag scheme

Each successful release publishes a multi-arch container image to
`ghcr.io/<owner>/robot-notes-server` with this tag set:

| Tag | When | Pinning level |
| --- | --- | --- |
| `vX.Y.Z` | release event | exact version, immutable in practice |
| `X.Y` | release event | follows latest patch |
| `X` | release event | follows latest minor |
| `latest` | release event | follows latest stable release |
| `sha-<7>` | release event | exact commit |

Production deployments SHOULD pin to `vX.Y.Z` (or by digest); preview
environments can ride `main`.

---

## Conventional-commits cheatsheet

Release-please derives the next version and CHANGELOG entries from
commit subjects. Stick to these prefixes:

| Prefix | Bumps | Appears in CHANGELOG |
| --- | --- | --- |
| `feat:` | minor | yes (Features) |
| `fix:` | patch | yes (Bug Fixes) |
| `perf:` | patch | yes (Performance) |
| `docs:` | none | yes (Documentation) |
| `revert:` | varies | yes (Reverts) |
| `chore:` / `ci:` / `build:` / `refactor:` / `test:` | none | hidden |

A breaking change is signalled by a `!` after the type or by a
`BREAKING CHANGE:` footer:

```
feat!: drop the legacy /v0 search endpoint

BREAKING CHANGE: Clients must call /search instead.
```

That bumps the major version once we're past 1.0; pre-1.0 it bumps
the minor (the manifest sets `bump-minor-pre-major: true`).

Scopes are optional but encouraged: `feat(server): …`, `fix(app): …`.

---

## Cutting a release

The flow is fully driven by merging a release PR.

1. Land conventional commits on `main` as normal. The CI workflow
   (`.github/workflows/ci.yml`) gates every PR with format, lint, full
   test suite, and a Dockerfile build dry-run.
2. The release-please workflow runs on every push to `main` and
   maintains a single open release PR titled
   `chore(main): release X.Y.Z`. Review it like any other PR — the
   diff is just `CHANGELOG.md` + `.release-please-manifest.json`.
3. **Merge** the release PR. The release-please workflow then, in the
   *same run*:
   - creates a `vX.Y.Z` git tag,
   - creates a GitHub release with the CHANGELOG entry as body,
   - builds and pushes the multi-arch image to ghcr.io (the `publish`
     job is gated on `release_created == true`, so routine pushes to
     `main` don't ship preview images).
4. Verify the tag set is live:
   ```
   docker pull ghcr.io/<owner>/robot-notes-server:vX.Y.Z
   docker manifest inspect ghcr.io/<owner>/robot-notes-server:vX.Y.Z
   ```
   The manifest should list both `linux/amd64` and `linux/arm64` under
   the same digest.

---

## Hotfix procedure

1. Branch from the release tag (or from `main` if the bug also exists
   there): `git switch -c hotfix/<short-name>`.
2. Land a `fix:` commit (and any `test:`/`docs:` companions) on `main`
   via PR.
3. Release-please opens (or updates) a release PR proposing the next
   patch version. Merge it.
4. Confirm `vX.Y.Z+1` is on ghcr per the verification step above.

If the fix only applies to an older minor branch, cut the patch from
that branch — release-please supports per-branch manifests, but
configure that explicitly the first time you need it.

---

## First-release walkthrough

For the very first release of the project (going from `0.0.0` to
`0.1.0`):

1. Ensure `main` has at least one `feat:` commit (otherwise
   release-please proposes a patch bump only). The bootstrap commit
   can be `feat: initial server scaffold`.
2. Wait for the release-please workflow to open its first release PR.
   Review the proposed `CHANGELOG.md`.
3. Merge the PR. The first `v0.1.0` tag and GitHub release are
   created automatically; the publish workflow runs and pushes the
   first image set.
4. Complete the one-time post-publish steps below.

---

## One-time bootstrap steps

These are owner/maintainer actions in repository settings — do them
once and forget.

### `RELEASE_PLEASE_TOKEN` PAT

The release PR is opened by release-please. If it's opened with the
default `secrets.GITHUB_TOKEN`, GitHub deliberately suppresses
downstream workflow events on it — meaning `ci.yml` won't run on the
release PR, and you can't gate the release merge on green checks.

1. Create a fine-grained PAT scoped to this repo with these
   permissions: **Contents: read+write**, **Pull requests: read+write**,
   **Workflows: read+write**.
2. Add it as repository secret `RELEASE_PLEASE_TOKEN`.

The release-please workflow already prefers `RELEASE_PLEASE_TOKEN`
when present and falls back to `GITHUB_TOKEN` during bootstrap.

### GHCR package visibility

The first push to GHCR creates a *private* package. To let external
consumers pull `ghcr.io/<owner>/robot-notes-server`:

1. Open the package page (`https://github.com/users/<owner>/packages/container/robot-notes-server`
   for personal accounts, or the org variant).
2. Settings → **Change visibility → Public**.
3. Settings → **Manage Actions access** → ensure the source repo has
   write access (this is automatic for repos under the same owner).
4. Settings → **Link to repository** → connect to this repo so
   "Packages" surfaces the SBOM and provenance attestations.

### Required status checks on `main`

To prevent direct pushes from skipping CI:

1. Settings → Branches → branch protection rule for `main`.
2. Require pull-request reviews before merging.
3. Require status checks to pass before merging — select the `dart`
   and `docker` jobs from `ci.yml`.
4. Require linear history (optional but recommended).

### Dependabot

Dependabot is configured at `.github/dependabot.yml`. Enabling it is
a no-op once that file lands; check Settings → Code security &
analysis to confirm it's on, then watch the first scan land its
initial PR set.

---

## Operating: agent-onboarding invites

The server exposes an invite flow for agents that want to bootstrap
themselves with a single fetch of an `onboarding.txt` bundle. The
bearer API key remains the only authentication primitive; an invite
is a single-use, time-bound capability that hands a freshly-generated
`X-Actor` and the API base URL to the agent in one shot.

### Mint an invite

Authenticated as the bearer key holder:

```sh
curl -X POST https://<host>/invites \
     -H "Authorization: Bearer $ROBOT_NOTES_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"label": "research-bot", "ttl_seconds": 3600}'
```

Response:

```json
{
  "token": "…opaque…",
  "url": "https://<host>/invites/…opaque…/onboarding.txt",
  "expires_at": "2026-04-25T13:00:00Z",
  "single_use": true,
  "label": "research-bot"
}
```

### Share the URL

Treat the invite URL like a credential — it is a bearer token in
plain sight. Send it over a confidential channel (e.g. an encrypted
DM or a secret manager handoff). Do not commit it, do not paste it in
public chat, and do not share it with more than one agent: the URL
is single-use and the second fetch returns 410.

### Revoke / inspect

Invites live under `data/invites/<token>.json`. Listing
(`GET /invites`, authenticated) shows pending/used invites. Deleting
the JSON file or hitting `DELETE /invites/<token>` cancels it
immediately — useful if you suspect the URL leaked before the agent
fetched it.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Release PR opens, but no tag after merge | `RELEASE_PLEASE_TOKEN` is missing or under-scoped. |
| Tag exists, but publish workflow didn't fire | Same as above; `GITHUB_TOKEN`-pushed tags don't trigger workflows. |
| `docker pull` says "manifest not found" | Image still building; wait for `publish` workflow to finish, then retry. |
| `docker manifest inspect` shows only one arch | Buildx cache regression — re-run the publish workflow. |
| Dependabot dashboard shows config errors | Indentation / scope typo in `.github/dependabot.yml`; YAML it locally before committing. |
