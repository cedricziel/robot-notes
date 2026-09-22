## ADDED Requirements

### Requirement: App Store submission captures fresh screenshots

The `submit_to_app_store` fastlane lane (both `ios` and `mac` platforms) SHALL regenerate App Store Connect screenshots before uploading a build for review, rather than relying on screenshots uploaded by hand at an earlier point in time. Screenshot capture SHALL run against sample data on an ephemeral, disposable server instance — never against a real user's data or a long-lived deployment.

#### Scenario: Submitting for review captures and uploads screenshots

- **WHEN** `fastlane ios submit_to_app_store` or `fastlane mac submit_to_app_store` runs
- **THEN** it SHALL capture iPhone, iPad, and Mac screenshots against a freshly seeded, disposable server instance before calling `upload_to_app_store`
- **AND** the upload SHALL include those freshly captured screenshots (`skip_screenshots: false`)

#### Scenario: A capture failure blocks submission

- **GIVEN** simulator boot, ephemeral server boot, seeding, or the screenshot-taking integration test fails
- **WHEN** `submit_to_app_store` runs
- **THEN** the lane SHALL fail before calling `upload_to_app_store`
- **AND** it SHALL NOT fall back to reusing whatever screenshots are already on disk or already published in App Store Connect

#### Scenario: Routine TestFlight releases do not capture screenshots

- **WHEN** `fastlane ios release` or `fastlane mac release` runs (the TestFlight-only lane, not a review submission)
- **THEN** it SHALL NOT run screenshot capture and SHALL NOT boot the ephemeral server

### Requirement: Screenshot capture never touches real user data

Screenshot capture SHALL run its own dedicated server process seeded with fictional sample content, isolated from any persistent deployment (e.g. the maintainer's live hive instance) and from its data or API key.

#### Scenario: Capture uses an ephemeral, isolated server

- **WHEN** screenshot capture runs
- **THEN** it SHALL start a new server process against a fresh temporary data directory and a capture-only API key
- **AND** it SHALL seed that server with fictional sample notes and a sample database before taking any screenshot
- **AND** it SHALL stop that server process and discard its temporary data directory once capture completes, whether capture succeeded or failed
