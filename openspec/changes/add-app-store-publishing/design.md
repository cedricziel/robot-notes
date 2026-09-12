## Context

The release workflow is already a fan-out from `resolve-tag`: every publish job keys off `needs.resolve-tag.outputs.tag_name` and uses `if: always() && needs.resolve-tag.result == 'success'` so a `workflow_dispatch` rerun with a tag input works. The Apple jobs join that fan-out rather than adding a second workflow, so one release run tells the whole story and one rerun path covers everything.

The maintainer's other apps (textfriend, PodDreamer) already use fastlane + match with the same Apple team, the same App Store Connect API key, and the same private certificates repo. This change reuses that convention so the secret names, lane names, and recovery steps are identical across projects.

## Decisions

**Pre-release = TestFlight, release = App Store.** The `release` lane uploads with `upload_to_testflight` and waits for processing so the build is installable by internal testers minutes after the release, and so the release body lands as the TestFlight changelog. App Store review takes days on a first submission, so it is a separate `submit_to_app_store` lane that attaches the already-processed build (`skip_binary_upload` + `build_number`) to the version and submits it with automatic release. GitHub's own release states drive the two: release-please writes a **draft** (`"draft": true`), the workflow publishes it as a **pre-release** with `GITHUB_TOKEN` (creates the tag, fires no workflow events), and a human promoting it to the latest release fires `release: released`, which runs the same `apple` job in submit mode with the build steps skipped. `resolve-tag` derives a `mode` output (`publish` / `submit`) so the container jobs stay off on the `released` event. `auto_release:false` exists for manual use.

Why draft rather than release-please's `prerelease: true`: that option only flags pre-1.0 versions as pre-releases. After 1.0 every cut would be a full release, `released` would fire immediately, and the submit would race the TestFlight upload of the same tag and fail on a build that does not exist yet.

**Flutter builds with `--config-only`; xcodebuild archives.** `flutter build <platform> --release --config-only --build-name --build-number` writes `Generated.xcconfig` and runs `pod install` without compiling. `build_app` then does the single real build with the Flutter script phases, which avoids building twice and keeps signing under fastlane's control.

**Manual signing flipped at build time.** The Xcode projects stay on automatic signing for local development. In the lane, `update_code_signing_settings` switches the Runner target's Release configuration to the match-provided "Apple Distribution" identity and profile. The change lives only in the runner's checkout.

**Build number = commit count.** `git rev-list --count HEAD` is monotonic on `main`, reproducible from the tag, and needs no write-back into `pubspec.yaml`. The marketing version comes from the tag (`v0.3.0` → `0.3.0`), falling back to `pubspec.yaml` for local runs.

**Shared metadata for both platforms.** iOS and macOS are one App Store Connect app record with one listing; `app/fastlane/metadata` is uploaded by both jobs. Screenshots are skipped in the pipeline and uploaded once by hand.

**Release notes from the GitHub release body.** The workflow writes the body to a file and the lane stages it into `metadata/en-US/release_notes.txt` before upload. The committed file is the fallback for local runs.

**macOS product renamed to "Robot Notes".** The Flutter template leaves `PRODUCT_NAME = app` and the iOS display name as "App". Both are visible to users and reviewers, so they are fixed as part of making the app store-ready.

## Risks / Trade-offs

- **First submission needs manual steps** (screenshots, reviewer demo server). The runbook lists them; until they are done the pipeline uploads fine but review will not pass.
- **A rerun of the same tag from the same commit is rejected by Apple** because the build number repeats. The runbook says to cut a new release instead.
- **Both platforms share one version.** If Apple rejects one, the other still releases; the fix ships in the next release for both.
- **macOS runner minutes are expensive.** Apple jobs only run on releases, never on PRs.
