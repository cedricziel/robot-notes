## MODIFIED Requirements

### Requirement: First-run flow captures server URL, API key, and actor name

On first launch (no saved configuration) the app SHALL present a setup screen requesting three values: server base URL, API key, and actor display name, laid out in a width-capped, centered card rather than stretching to the window width. The app SHALL validate the configuration by issuing an authenticated request (e.g. `GET /healthz` followed by `GET /notes?limit=1`) before persisting it. On validation failure the app SHALL display the error code from the server and SHALL allow the user to correct and retry. While the user is entering the server URL, the app SHALL show a live, best-effort reachability indicator (checking / reachable / unreachable) next to the field, determined by a `GET /healthz` probe; this indicator is informational only and SHALL NOT gate proceeding.

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

#### Scenario: The setup card does not stretch to a wide window

- **GIVEN** the app window is wider than the card's maximum width
- **WHEN** the setup screen renders
- **THEN** the form SHALL render inside a centered card no wider than 420 logical pixels, not stretched to the window's full width

#### Scenario: A live check shows the server is reachable before submitting

- **GIVEN** the user is entering the server URL
- **WHEN** the app's `GET /healthz` probe responds 200 after the user pauses typing
- **THEN** the app SHALL show a reachable indicator next to the URL field without requiring the user to press Continue or Connect

#### Scenario: A live check surfaces an unreachable server before submitting

- **GIVEN** the user is entering the server URL
- **WHEN** the app's `GET /healthz` probe fails or times out after the user pauses typing
- **THEN** the app SHALL show an unreachable indicator next to the URL field, without disabling Continue

#### Scenario: A stale reachability check does not override a newer one

- **GIVEN** the user changed the URL again before an earlier reachability probe finished
- **WHEN** the earlier probe's response arrives after the newer probe's response
- **THEN** the app SHALL keep showing the newer probe's result
