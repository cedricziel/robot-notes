## MODIFIED Requirements

### Requirement: First-run flow captures server URL, API key, and actor name

On first launch (no saved configuration) the app SHALL present a setup screen requesting a server base URL, then offer two ways to authenticate: manual entry of an API key and actor display name, or — on any platform, when the server advertises `robotnotes_oidc_login_supported: true` in its `/.well-known/oauth-authorization-server` document — a "Sign in" option that runs the app's own OAuth 2.1 authorization-code-with-PKCE flow against that server. The app SHALL validate a manually entered configuration by issuing an authenticated request (e.g. `GET /healthz` followed by `GET /notes?limit=1`) before persisting it, and SHALL allow the user to correct and retry on failure. When the server does not advertise OIDC support, only manual API key entry SHALL be offered.

#### Scenario: Successful setup persists configuration

- **GIVEN** the app has no saved configuration
- **WHEN** the user enters a valid URL, key, and name and submits
- **THEN** the app SHALL store all three in secure storage and proceed to the notes list

#### Scenario: Invalid key surfaces error

- **GIVEN** the app has no saved configuration
- **WHEN** the user enters an URL and a wrong key and submits
- **THEN** the app SHALL display an error referencing the 401 response and SHALL not persist the configuration

#### Scenario: Unreachable server surfaces network error

- **GIVEN** the user enters an URL pointing at no server
- **WHEN** the user submits
- **THEN** the app SHALL display a network error and SHALL not persist the configuration

#### Scenario: Sign-in option appears only when the server supports it

- **GIVEN** the user has entered a server URL whose `/.well-known/oauth-authorization-server` document contains `robotnotes_oidc_login_supported: true`
- **WHEN** the setup screen loads that server's capabilities, on any build (desktop, web, iOS, or Android)
- **THEN** the app SHALL display a "Sign in" option alongside manual API key entry

#### Scenario: Sign-in option is absent when unsupported

- **GIVEN** the user has entered a server URL whose discovery document omits `robotnotes_oidc_login_supported`
- **WHEN** the setup screen loads
- **THEN** the app SHALL offer only manual API key entry

#### Scenario: Successful sign-in persists an OAuth session

- **GIVEN** the server supports OIDC login
- **WHEN** the user chooses "Sign in" on a desktop or web build, completes the provider's login in the opened browser, and is redirected back
- **THEN** the app SHALL exchange the resulting code for an access and refresh token, store them in secure storage, and proceed to the notes list using the identity's display name as the actor

#### Scenario: Successful mobile sign-in persists an OAuth session

- **GIVEN** the server supports OIDC login and the app is running on iOS or Android
- **WHEN** the user chooses "Sign in", completes the provider's login in the browser sheet (`ASWebAuthenticationSession` on iOS, Custom Tabs on Android) opened over the authorize URL, and the sheet is redirected to the app's `com.cedricziel.robotnotes.app://oauth/callback` scheme
- **THEN** the app SHALL exchange the resulting code for an access and refresh token, store them in secure storage, and proceed to the notes list using the identity's display name as the actor

### Requirement: API key and actor name are stored in platform-secure storage

The app SHALL store the active credential using a per-platform secure mechanism: Keychain on iOS/macOS, Keystore on Android, DPAPI on Windows, libsecret on Linux, and `window.localStorage` on Web (acknowledged trade-off, documented in the app). The stored credential is either a manually entered API key and actor name, or — for a sign-in-established session — an OAuth access token, refresh token, and the actor name derived from the signed-in identity. Neither the API key nor an OAuth token SHALL ever be written to logs or to plaintext app preferences.

#### Scenario: Key persists across app restarts

- **GIVEN** the user has completed manual setup
- **WHEN** the app is closed and reopened
- **THEN** the saved key SHALL be loaded automatically and the app SHALL go directly to the notes list

#### Scenario: OAuth session persists across app restarts

- **GIVEN** the user has completed sign-in
- **WHEN** the app is closed and reopened
- **THEN** the saved access/refresh tokens SHALL be loaded automatically, refreshed if needed, and the app SHALL go directly to the notes list

#### Scenario: Key is not present in app logs

- **GIVEN** the app is configured with a key
- **WHEN** any log output is produced during normal operation
- **THEN** the API key value SHALL NOT appear in any logged string

#### Scenario: OAuth tokens are not present in app logs

- **GIVEN** the app is configured with a sign-in-established session
- **WHEN** any log output is produced during normal operation
- **THEN** neither the access token nor the refresh token SHALL appear in any logged string
