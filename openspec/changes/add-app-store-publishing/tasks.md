## 1. Store-ready app bundle

- [x] 1.1 Set `CFBundleDisplayName` / `CFBundleName` to "Robot Notes" and `ITSAppUsesNonExemptEncryption=false` in `app/ios/Runner/Info.plist`
- [x] 1.2 Set `ITSAppUsesNonExemptEncryption=false` and `LSApplicationCategoryType` in `app/macos/Runner/Info.plist`; `PRODUCT_NAME = Robot Notes` in `AppInfo.xcconfig`
- [x] 1.3 Add `PRIVACY.md` at the repo root

## 2. fastlane

- [x] 2.1 Add `app/Gemfile` + `Gemfile.lock` pinning fastlane
- [x] 2.2 Add `app/fastlane/Appfile`, `Matchfile` (appstore, `com.cedricziel.robotnotes.app`), `.env.default`
- [x] 2.3 Add `app/fastlane/Fastfile` with `ios build|release`, `mac build|release`, `bootstrap_app`, `bootstrap_signing`, `sync_metadata`
- [x] 2.4 Add listing metadata, age rating, and review information under `app/fastlane`
- [x] 2.5 Ignore `fastlane/.env`, `README.md`, `report.xml`, bundler vendor dirs

## 3. Workflow

- [x] 3.1 Add the `apple` matrix job to `.github/workflows/release-please.yml` gated on `resolve-tag`
- [x] 3.2 Run `actionlint` on the workflow
- [x] 3.3 Add the `bundler` ecosystem for `/app` to `.github/dependabot.yml`

## 4. Bootstrap (external state)

- [x] 4.1 Add read-only deploy key `robot-notes-fastlane-match-ci` to `cedricziel/certificates`
- [x] 4.2 `fastlane bootstrap_app`: register bundle ID (iOS + macOS) and create the "Robot Notes" app record
- [x] 4.3 `fastlane bootstrap_signing`: mint development + appstore profiles for iOS and macOS into the certificates repo
- [x] 4.4 `fastlane sync_metadata` once; App Privacy ("Data Not Collected") published in the App Store Connect UI
- [x] 4.5 Set repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_KEYCHAIN_PASSWORD`, `MATCH_DEPLOY_KEY`
- [x] 4.6 Store the new deploy key and keychain password in 1Password

## 5. Verification

- [x] 5.1 Local `bundle exec fastlane ios build` and `bundle exec fastlane mac build` produce a signed IPA / PKG
- [x] 5.2 `RELEASING.md` documents flow, secrets, re-run, first-submission checklist, troubleshooting
- [x] 3.4 Set `"draft": true` in `release-please-config.json` and publish the draft as a pre-release in the workflow
- [ ] 5.3 After merge: `workflow_dispatch` against the latest tag uploads both builds to TestFlight; promoting a pre-release submits them

## Definition of Done

- A GitHub release created by release-please results in an iOS and a macOS build in TestFlight with no manual step in between
- Promoting that pre-release to the latest release submits its builds for App Store review without rebuilding
- `RELEASING.md` lets a maintainer rerun, debug, or re-bootstrap the pipeline without reading the workflow source
- The `release-pipeline` spec describes the App Store publish requirements
