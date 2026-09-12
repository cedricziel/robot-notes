## Why

Every release already ships the server as a container image, but the Flutter client only exists as source. Anyone who wants the app on an iPhone, iPad, or Mac has to build and sign it themselves. Shipping the client through the App Store as part of the same release run makes a release complete: server image and client binaries land together, from the same tag, with no manual signing.

## What Changes

- **NEW** `apple` matrix job (`ios`, `macos`) in `.github/workflows/release-please.yml`, gated on the same `resolve-tag` output as the container build, running on `macos-26`
- **NEW** fastlane setup under `app/` (`Gemfile`, `fastlane/Appfile`, `Matchfile`, `Fastfile`) with `ios release` and `mac release` lanes: match (read-only in CI) → `flutter build --config-only` → `build_app` → `upload_to_testflight`; and `submit_to_app_store` lanes that attach an existing TestFlight build to the App Store version and submit it for review with automatic release
- **NEW** App Store listing metadata under `app/fastlane/metadata`, age rating, and a root `PRIVACY.md` the listing links to
- **NEW** Build number derived from `git rev-list --count HEAD`; marketing version from the release tag
- **MODIFIED** iOS and macOS `Info.plist` declare `ITSAppUsesNonExemptEncryption=false`; macOS declares `LSApplicationCategoryType`; the product is named "Robot Notes" instead of "app"
- **MODIFIED** `RELEASING.md` gains an App Store section (flow, secrets, re-run, first-submission checklist, troubleshooting)
- **MODIFIED** Dependabot covers the `bundler` ecosystem under `/app`

## Capabilities

### Modified Capabilities

- `release-pipeline`: release-please now cuts pre-releases (draft → published as pre-release by the workflow); a pre-release additionally publishes signed iOS and macOS builds to TestFlight; promoting it to a full release submits that tag's builds for App Store review; the workflow's secret inventory grows accordingly

## Non-goals

- Android, Windows, Linux, or web distribution of the client
- Screenshot generation or upload (done once by hand in App Store Connect)
- External TestFlight testing groups (builds go to internal testers only)
- Submitting for App Store review automatically on every release
- Building the app on pull requests (macOS runner minutes are reserved for releases)
- Notarized Developer ID builds outside the App Store

## Impact

- `.github/workflows/release-please.yml`: one new matrix job; no change to the container jobs
- `app/`: fastlane config, Gemfile, metadata, plist and xcconfig edits
- Repository secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_KEYCHAIN_PASSWORD`, `MATCH_DEPLOY_KEY`
- External state: bundle ID and app record in App Store Connect; profiles in the private certificates repo; a read-only deploy key on that repo
