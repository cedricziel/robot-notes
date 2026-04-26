# flutter-client Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Flutter app targets multiple platforms from a single codebase

The Flutter client SHALL build and run on at least Android, iOS, macOS, Windows, Linux, and Web from the same source. Platform-specific code SHALL be limited to secure storage and platform integration glue. Functionality SHALL be equivalent across platforms in v1.

#### Scenario: Build runs for each target

- **WHEN** `flutter build` is invoked for `apk`, `ios`, `macos`, `windows`, `linux`, and `web`
- **THEN** each build SHALL succeed and produce a runnable artifact

### Requirement: First-run flow captures server URL, API key, and actor name

On first launch (no saved configuration) the app SHALL present a setup screen requesting three values: server base URL, API key, and actor display name. The app SHALL validate the configuration by issuing an authenticated request (e.g. `GET /healthz` followed by `GET /notes?limit=1`) before persisting it. On validation failure the app SHALL display the error code from the server and SHALL allow the user to correct and retry.

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

### Requirement: API key and actor name are stored in platform-secure storage

The app SHALL store the API key and actor name using a per-platform secure mechanism: Keychain on iOS/macOS, Keystore on Android, DPAPI on Windows, libsecret on Linux, and `window.localStorage` on Web (acknowledged trade-off, documented in the app). The API key SHALL NEVER be written to logs or to plaintext app preferences.

#### Scenario: Key persists across app restarts

- **GIVEN** the user has completed setup
- **WHEN** the app is closed and reopened
- **THEN** the saved key SHALL be loaded automatically and the app SHALL go directly to the notes list

#### Scenario: Key is not present in app logs

- **GIVEN** the app is configured with a key
- **WHEN** any log output is produced during normal operation
- **THEN** the API key value SHALL NOT appear in any logged string

### Requirement: Notes list view shows server state

The app SHALL provide a list view that pages through `GET /notes`, showing each note's title and updated time, and supports pull-to-refresh and infinite scroll via `next_cursor`. The list SHALL update in response to `changed` WebSocket events without manual refresh.

#### Scenario: Initial load fetches first page

- **WHEN** the user opens the notes list
- **THEN** the app SHALL request `GET /notes` and render the returned items

#### Scenario: Live changed event updates the list

- **GIVEN** the notes list is open and subscribed to `*`
- **WHEN** the server broadcasts `{"type":"changed","note_id":"X","action":"updated",...}`
- **THEN** the entry for `X` SHALL move to its new position and SHALL display the updated metadata without manual refresh

#### Scenario: Live created event prepends a new entry

- **WHEN** a new note is created elsewhere and the WS broadcasts the `changed` event
- **THEN** a new list entry SHALL appear without manual refresh

#### Scenario: Live deleted event removes the entry

- **WHEN** a note is deleted elsewhere and the WS broadcasts the `changed` event
- **THEN** the entry for that note SHALL be removed from the list

### Requirement: Note view supports edit, lock, and concurrency UX

When the user opens a note, the app SHALL `GET /notes/{id}`, subscribe to its WS events, and acquire the editor lock before allowing edits. While editing, the app SHALL heartbeat the lock periodically. On save the app SHALL `PUT /notes/{id}` with the version it last loaded. The app SHALL handle 409 by reloading the server state and presenting a "your local changes are out of date" UI. The app SHALL handle 423 by switching to read-only mode and surfacing the lock holder.

#### Scenario: Edit acquires the lock

- **WHEN** the user enters edit mode on a note
- **THEN** the app SHALL `POST /notes/{id}/lock` and proceed only on 200

#### Scenario: Heartbeat extends the lock during editing

- **GIVEN** the user is in edit mode
- **WHEN** roughly half the TTL elapses between keystrokes
- **THEN** the app SHALL `PUT /notes/{id}/lock` to extend it

#### Scenario: Save uses If-Match

- **GIVEN** a note loaded at version 5
- **WHEN** the user saves
- **THEN** the app SHALL send `PUT /notes/{id}` with header `If-Match: 5`

#### Scenario: 409 prompts the user to reconcile

- **GIVEN** the local copy is at version 5 but the server is at version 7
- **WHEN** the save returns 409
- **THEN** the app SHALL present the server's current title and content, the user's local edits, and a clear path to retry the save against the new version

#### Scenario: 423 switches to read-only

- **GIVEN** another actor holds the lock
- **WHEN** the user opens the note
- **THEN** the app SHALL display a banner naming the lock holder and SHALL disable editing controls

#### Scenario: Closing the editor releases the lock

- **WHEN** the user navigates away from a note they had locked
- **THEN** the app SHALL `DELETE /notes/{id}/lock`

### Requirement: Live presence and lock state are surfaced in the note view

While the note view is open the app SHALL display a presence indicator (list of viewers' actor names) and a lock indicator (current holder, if any) updated in real time from `presence` and `lock` WebSocket events.

#### Scenario: Presence indicator updates on subscribe/unsubscribe

- **GIVEN** the note view is open
- **WHEN** another actor subscribes to or unsubscribes from the note
- **THEN** the presence indicator SHALL update to reflect the new viewer set

#### Scenario: Lock indicator updates on lock event

- **WHEN** the server emits a `lock` event for the open note
- **THEN** the lock indicator SHALL update to show the new holder or "unlocked"

### Requirement: App provides a search view backed by /search

The app SHALL provide a search view that issues `GET /search?q=...` as the user types (debounced ~250ms) and renders titles, snippets (rendering `<mark>` markers as visual highlight), and ranks. Tapping a result SHALL open that note in the note view.

#### Scenario: Debounced search triggers request

- **GIVEN** the search view is open
- **WHEN** the user types `meet`
- **THEN** the app SHALL issue at most one `GET /search?q=meet` request after a ~250ms quiet period

#### Scenario: Empty input clears results

- **WHEN** the user empties the search field
- **THEN** the app SHALL clear results and SHALL NOT issue a request

#### Scenario: Snippet markers are rendered as visual highlight

- **GIVEN** the server returns `snippet: "...the <mark>architecture</mark> doc..."`
- **WHEN** the result is rendered
- **THEN** the word `architecture` SHALL be visually emphasized (color, weight, or background)

### Requirement: WebSocket connection is managed with auto-reconnect

The app SHALL maintain at most one WebSocket connection while signed in. On disconnect the app SHALL attempt to reconnect with exponential backoff (initial 500ms, max 30s). On every successful reconnect the app SHALL re-authenticate, re-subscribe to all current views, and refresh on-screen data.

#### Scenario: Disconnect triggers reconnect

- **GIVEN** the WS connection is open and a note view is subscribed to note X
- **WHEN** the connection drops
- **THEN** the app SHALL attempt reconnection with backoff

#### Scenario: Reconnect re-subscribes

- **WHEN** the WS connection is re-established
- **THEN** the app SHALL re-send the auth message and SHALL re-send subscribe messages for note X (and `*` if the list view is open)

#### Scenario: Reconnect refreshes stale views

- **WHEN** the WS connection is re-established after being disconnected for more than 5 seconds
- **THEN** the open note view (if any) SHALL re-issue `GET /notes/{id}` to ensure the user sees current state

