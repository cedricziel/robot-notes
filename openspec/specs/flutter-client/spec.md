# flutter-client Specification

## Purpose

TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.

## Requirements

### Requirement: Flutter app targets multiple platforms from a single codebase

The Flutter client SHALL build and run on at least Android, iOS, macOS, Windows, Linux, and Web from the same source. Platform-specific code SHALL be limited to secure storage and platform integration glue. Functionality SHALL be equivalent across platforms in v1.

#### Scenario: Build runs for each target

- **WHEN** `flutter build` is invoked for `apk`, `ios`, `macos`, `windows`, `linux`, and `web`
- **THEN** each build SHALL succeed and produce a runnable artifact

### Requirement: The UI exposes an accessibility tree on every platform

The app SHALL enable Flutter's semantics tree at startup on Web, where Flutter leaves it off by default, so screen readers and browser automation see the same controls a sighted user does. On native platforms the app SHALL leave enabling semantics to the operating system. Every icon-only button SHALL carry a tooltip, which doubles as its accessible label.

#### Scenario: Web build exposes interactive elements

- **GIVEN** the app is running in a browser
- **WHEN** an assistive technology or automation inspects the page
- **THEN** it SHALL find the app's buttons, text fields, and list items in the accessibility tree without first activating a hidden "enable accessibility" control

#### Scenario: Icon buttons are labelled

- **WHEN** any screen renders an icon-only button
- **THEN** the button SHALL have a tooltip naming its action

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

The app SHALL provide a list view that pages through `GET /notes`, showing each note's title and updated time in the device's local time zone, and supports pull-to-refresh, an explicit refresh action, and infinite scroll via `next_cursor`. The list SHALL update in response to `changed` WebSocket events without manual refresh, and SHALL re-fetch when the user returns from a note so edits show even when the realtime stream is unavailable. When a fetch fails the app SHALL surface the failure without hiding items that already loaded.

#### Scenario: Initial load fetches first page

- **WHEN** the user opens the notes list
- **THEN** the app SHALL request `GET /notes` and render the returned items

#### Scenario: Refresh action re-fetches the list

- **GIVEN** the notes list is open
- **WHEN** the user activates the Refresh action in the app bar
- **THEN** the app SHALL request `GET /notes` again and render the returned items

#### Scenario: Returning from a note refreshes the list

- **GIVEN** the user opened a note from the list and saved a new version
- **WHEN** the note view is closed
- **THEN** the list SHALL request `GET /notes` again and show the note's new version and updated time

#### Scenario: Failed fetch shows a non-blocking error with retry

- **GIVEN** the list has already rendered items
- **WHEN** a refresh or page fetch fails
- **THEN** the app SHALL show an error strip above the list carrying the server's `message` (or a generic fallback) and a retry control, and the existing items SHALL remain visible
- **AND** activating retry SHALL re-issue `GET /notes` and clear the strip on success

#### Scenario: Updated time is shown in local time

- **GIVEN** a note whose `updated_at` is `2026-09-12T10:28:00Z`
- **WHEN** the list renders on a device in UTC+2
- **THEN** the entry SHALL show `2026-09-12 12:28` with no UTC marker

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

#### Scenario: Entering edit mode uses the note as it exists after the lock is acquired

- **GIVEN** the note was loaded at version 1 and another actor has since updated it to version 2
- **WHEN** the user enters edit mode and the lock is acquired
- **THEN** the app SHALL `GET /notes/{id}` again and seed the edit buffers and `If-Match` baseline from version 2

#### Scenario: Failed re-fetch after acquiring the lock releases it

- **GIVEN** the lock was acquired
- **WHEN** the follow-up `GET /notes/{id}` fails
- **THEN** the app SHALL `DELETE /notes/{id}/lock`, stay in read-only mode, and surface the error

#### Scenario: Heartbeat extends the lock during editing

- **GIVEN** the user is in edit mode
- **WHEN** roughly half the TTL elapses between keystrokes
- **THEN** the app SHALL `PUT /notes/{id}/lock` to extend it

#### Scenario: Typing mid-text keeps the caret in place

- **GIVEN** the user is in edit mode with the caret placed inside the title or content
- **WHEN** the user types
- **THEN** the characters SHALL be inserted at the caret and the caret SHALL stay right after them; syncing the edit buffers back into the fields SHALL NOT move it

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

### Requirement: Unsaved edits are not discarded without confirmation

When the user leaves the note view — via the close button, the browser back button, or the OS back gesture — while the edit buffers differ from the loaded note, the app SHALL ask for confirmation before releasing the lock and discarding the edits. Leaving with unchanged buffers SHALL NOT prompt.

#### Scenario: Leaving with unsaved edits prompts

- **GIVEN** the user is editing a note and has changed the title or content
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL show a "Discard changes?" prompt and SHALL stay in the editor until they choose

#### Scenario: Keep editing

- **WHEN** the user chooses "Keep editing"
- **THEN** the app SHALL dismiss the prompt, keep the lock, and preserve the edit buffers

#### Scenario: Discard

- **WHEN** the user chooses "Discard"
- **THEN** the app SHALL `DELETE /notes/{id}/lock`, drop the edits, and leave the note view

#### Scenario: Leaving without edits does not prompt

- **GIVEN** the user is editing but the buffers match the loaded note
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL release the lock and leave without prompting

### Requirement: Save and lock outcomes are surfaced in the note view

The note view SHALL confirm a completed save and SHALL show the server's message when a save or lock acquisition fails, so the user is never left silently in the editor. Outcomes the view already renders — 409 (conflict view) and 423 (lock banner) — SHALL NOT additionally produce a message.

#### Scenario: Successful save is confirmed

- **GIVEN** the user is editing a note
- **WHEN** the save returns 200 with version 7
- **THEN** the app SHALL show a brief "Saved (v7)" confirmation and stay in edit mode

#### Scenario: Failed save shows the server message

- **GIVEN** the user is editing a note
- **WHEN** the save fails with a status other than 409 or 423 (for example 400 for an empty title)
- **THEN** the app SHALL show a message containing the server's `message` and SHALL stay in edit mode with the edits intact

#### Scenario: Failed lock acquisition shows the server message

- **WHEN** `POST /notes/{id}/lock` fails with a status other than 423
- **THEN** the app SHALL show a message containing the server's `message` and remain read-only

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

#### Scenario: Search error is shown to the user

- **GIVEN** the user types a query the server rejects (for example an unbalanced quote, which returns 400)
- **WHEN** the response arrives
- **THEN** the app SHALL display the server's `message` (or a generic fallback); if results from an earlier query are still on screen they SHALL stay visible beneath the error

#### Scenario: New query over old results shows progress

- **GIVEN** results from an earlier query are on screen
- **WHEN** the user types a new query
- **THEN** the app SHALL show a progress indicator while the request is in flight without clearing the earlier results

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

#### Scenario: Reconnect after a stale outage refreshes the list

- **GIVEN** the notes list is open and the connection has been down for more than 5 seconds
- **WHEN** the WS connection is re-established
- **THEN** the app SHALL request `GET /notes` again and render the returned items

### Requirement: Realtime connection state is visible in the notes list

The notes list SHALL show a strip above the list whenever the WebSocket connection is not established: "Reconnecting…" while the reconnect loop runs, and "Connection lost — showing cached notes" once the outage has lasted longer than the stale threshold. While connected, nothing SHALL be shown. Already-loaded notes SHALL stay visible and usable throughout.

#### Scenario: Connected shows no indicator

- **GIVEN** the WS connection is established
- **WHEN** the notes list renders
- **THEN** no connection strip SHALL be shown

#### Scenario: Short outage shows reconnecting

- **WHEN** the WS connection drops
- **THEN** the list SHALL show "Reconnecting…" above the loaded notes until the connection is re-established

#### Scenario: Long outage marks the list as cached

- **WHEN** the WS connection has been down for more than the stale threshold
- **THEN** the strip SHALL read "Connection lost — showing cached notes" and SHALL stay until the connection is re-established
