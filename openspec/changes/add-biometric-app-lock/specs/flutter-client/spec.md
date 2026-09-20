## ADDED Requirements

### Requirement: App can be locked behind device authentication

The account surface SHALL offer an "App lock" switch wherever the device can authenticate its owner (biometrics, or a device passcode), and SHALL omit it everywhere else. Changing the switch in either direction SHALL first require the user to authenticate; a cancelled or failed prompt SHALL leave it unchanged. The setting SHALL be stored per device and SHALL NOT be sent to the server.

While the lock is on, a connected session SHALL start locked, and SHALL lock whenever the app leaves the foreground. A locked app SHALL show only a lock screen — the notes, their state, and the realtime connection are kept but not shown, focusable, or exposed to assistive technology — and SHALL prompt for authentication when it opens or returns to the foreground. If that prompt is cancelled or fails, the lock screen SHALL stay and offer an "Unlock" button to try again. The system authentication sheet itself SHALL NOT cause the app to re-lock. On phones, the content SHALL also be covered while the app is inactive so the app-switcher snapshot does not show notes. Copy SHALL name the device's method ("Face ID", "Touch ID", "fingerprint", "face unlock") where known and fall back to "your device passcode".

If the lock is on but the device can no longer authenticate its owner, the app SHALL turn the lock off rather than lock the user out. Disconnecting from the server SHALL turn the lock off.

#### Scenario: Turning the lock on requires authentication

- **GIVEN** the app lock is off on a device with Face ID
- **WHEN** the user turns on "App lock" in the account surface and authenticates
- **THEN** the lock SHALL be on and the app SHALL stay unlocked

#### Scenario: Failed prompt leaves the lock off

- **GIVEN** the app lock is off
- **WHEN** the user turns on "App lock" and the authentication prompt fails or is cancelled
- **THEN** the lock SHALL remain off

#### Scenario: Cold start with the lock on

- **GIVEN** the app lock is on
- **WHEN** the app starts
- **THEN** the notes SHALL NOT be shown, the authentication prompt SHALL open, and on success the app SHALL show the notes

#### Scenario: Retrying after a cancelled prompt

- **GIVEN** the app is locked and the automatic prompt was cancelled
- **WHEN** the user taps "Unlock" and authenticates
- **THEN** the app SHALL show the screen the user was on

#### Scenario: Leaving the foreground locks the app

- **GIVEN** the app lock is on and the app is unlocked on a note
- **WHEN** the app is sent to the background and brought back
- **THEN** the lock screen SHALL be shown until the user authenticates, after which the same note SHALL be showing

#### Scenario: Unsupported device

- **GIVEN** the device cannot authenticate its owner (for example web or Linux)
- **WHEN** the user opens the account surface
- **THEN** no "App lock" switch SHALL be shown

#### Scenario: Disconnect turns the lock off

- **GIVEN** the app lock is on
- **WHEN** the user disconnects from the server
- **THEN** the lock SHALL be off, and the setup screen SHALL NOT ask for authentication
