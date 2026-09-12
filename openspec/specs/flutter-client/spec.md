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

#### Scenario: Overlapping refreshes coalesce into one request

- **GIVEN** a refresh is already in flight (e.g. from pull-to-refresh)
- **WHEN** another refresh is requested before it completes (e.g. a stale-reconnect refetch)
- **THEN** the app SHALL NOT issue a second `GET /notes` and SHALL apply the single in-flight request's result to both callers

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

### Requirement: Notes list can delete a note after confirmation

The list view SHALL offer a "Delete note" action on each entry, opened via long-press or (on desktop/web) right-click. Choosing it SHALL ask the user to confirm before anything is sent. On confirmation the app SHALL `DELETE /notes/{id}`, remove the entry from the list, and show a brief "Note deleted" confirmation. A 404 from the server SHALL be treated as success, since the note is gone either way. Any other error SHALL keep the entry in the list and surface the failure.

#### Scenario: Delete with confirmation

- **GIVEN** the notes list is open
- **WHEN** the user long-presses (or right-clicks) an entry, chooses "Delete note", and confirms
- **THEN** the app SHALL `DELETE /notes/{id}`, remove the entry from the list, and show "Note deleted"

#### Scenario: Cancel keeps the note

- **GIVEN** the delete confirmation is showing for an entry
- **WHEN** the user cancels
- **THEN** no request SHALL be sent and the entry SHALL remain in the list

#### Scenario: Delete of an already-removed note still clears it from the list

- **GIVEN** the delete confirmation is showing for an entry
- **WHEN** the server responds `404` to the `DELETE` request
- **THEN** the app SHALL treat the note as deleted and remove the entry from the list

#### Scenario: Failed delete keeps the entry

- **GIVEN** the delete confirmation is showing for an entry
- **WHEN** the server responds with an error other than `404`
- **THEN** the entry SHALL remain in the list and the app SHALL surface the failure

### Requirement: Note view supports edit, lock, and concurrency UX

When the user opens a note, the app SHALL `GET /notes/{id}`, subscribe to its WS events, and acquire the editor lock before allowing edits. While editing, the app SHALL heartbeat the lock periodically. On save the app SHALL `PUT /notes/{id}` with the version it last loaded. The app SHALL handle 409 by presenting a conflict view with the server's title and content beside the user's own, editable, title and content; the view SHALL mark the title when the two differ and SHALL mark the content lines each side has that the other does not. The user SHALL be able to take the server's version, or edit their own version in place and save it against the server's current version. The app SHALL handle 423 by switching to read-only mode and surfacing the lock holder.

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

#### Scenario: Conflict view shows both titles

- **GIVEN** the save returned 409 and the server's title differs from the user's
- **WHEN** the conflict view is shown
- **THEN** the server pane SHALL show the server's title, the user's pane SHALL show the user's title, and both SHALL be marked as differing

#### Scenario: Conflict view marks the lines the versions do not share

- **GIVEN** the server's content is `a`, `b`, `c` and the user's is `a`, `b`, `d`
- **WHEN** the conflict view is shown
- **THEN** the server pane SHALL mark `c`, the user's pane SHALL mark `d`, and neither SHALL mark `a` or `b`

#### Scenario: Editing yours in the conflict view and saving mine sends the edited text

- **GIVEN** the conflict view is shown with the server at version 7
- **WHEN** the user edits the content in the "Yours" pane and taps "Save mine"
- **THEN** the app SHALL send `PUT /notes/{id}` with the edited title and content and `If-Match: 7`

#### Scenario: Conflict panes stack on narrow screens

- **WHEN** the conflict view is narrower than 600 logical pixels
- **THEN** the server pane SHALL be shown above the user's pane instead of beside it

#### Scenario: 423 switches to read-only

- **GIVEN** another actor holds the lock
- **WHEN** the user opens the note
- **THEN** the app SHALL display a banner naming the lock holder and SHALL disable editing controls

#### Scenario: Closing the editor releases the lock

- **WHEN** the user navigates away from a note they had locked
- **THEN** the app SHALL `DELETE /notes/{id}/lock`

#### Scenario: Keyboard shortcuts save and close

- **GIVEN** the user is editing a note, including while a text field has focus
- **WHEN** they press Cmd+S (macOS) or Ctrl+S (other platforms)
- **THEN** the app SHALL save the note the same way as tapping "Save"
- **WHEN** they press Escape
- **THEN** the app SHALL trigger the same close flow as tapping the close button, prompting to discard if there are unsaved edits

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

### Requirement: Note view can delete the note after confirmation

The note view SHALL offer a "Delete note" action in an overflow menu while the note is in read-only mode. Choosing it SHALL ask the user to confirm before anything is sent. On confirmation the app SHALL `DELETE /notes/{id}`, close the note view, and show a brief "Note deleted" confirmation that outlives the closed view. A 404 from the server SHALL be treated as success, since the note is gone either way. Any other error SHALL keep the note open and surface the failure.

#### Scenario: Delete with confirmation

- **GIVEN** a note is open in read-only mode
- **WHEN** the user chooses "Delete note" and confirms
- **THEN** the app SHALL `DELETE /notes/{id}`, close the note view, and show "Note deleted"

#### Scenario: Cancel keeps the note

- **GIVEN** the delete confirmation is showing
- **WHEN** the user cancels
- **THEN** the app SHALL NOT send `DELETE /notes/{id}` and the note SHALL stay open unchanged

#### Scenario: Delete while editing releases the lock first

- **GIVEN** the user holds the editor lock on the note
- **WHEN** the note is deleted
- **THEN** the app SHALL `DELETE /notes/{id}/lock` before `DELETE /notes/{id}`

#### Scenario: Delete of an already-removed note still closes the view

- **WHEN** `DELETE /notes/{id}` returns 404
- **THEN** the app SHALL treat the note as deleted and close the view

#### Scenario: Failed delete keeps the note open

- **WHEN** `DELETE /notes/{id}` fails with any other error
- **THEN** the note view SHALL stay open in read-only mode and the app SHALL surface the error

### Requirement: A newly created note opens in edit mode

When the user creates a note from the list, the app SHALL open it straight into the editor: after `POST /notes` and `GET /notes/{id}` it SHALL acquire the lock, show the editor, focus the title field, and select the placeholder title so that typing replaces it. Opening an existing note from the list or search SHALL still start read-only.

#### Scenario: Create opens the editor with the title selected

- **WHEN** the user taps the create action and `POST /notes` succeeds
- **THEN** the app SHALL open the note, `POST /notes/{id}/lock`, and show the editor with the title field focused and its full text selected

#### Scenario: Lock unavailable on a new note

- **GIVEN** the lock request for the new note fails
- **WHEN** the note opens
- **THEN** the app SHALL fall back to the read-only view with the usual lock feedback

### Requirement: Note view renders the body as Markdown

In view mode the app SHALL render the note content as Markdown: headings, lists, emphasis, inline code, fenced code blocks, and links (styled; opening them is not yet supported). The rendered text SHALL be selectable. Edit mode SHALL keep showing the raw Markdown source in a plain text field.

#### Scenario: Markdown syntax is rendered, not shown verbatim

- **GIVEN** a note whose content is `# Heading`, a `- item` bullet, and `` `code` ``
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show "Heading" styled as a heading, "item" as a list entry, and "code" as inline code, and SHALL NOT show the `#`, `-`, or backtick markers

#### Scenario: Edit mode shows the Markdown source

- **WHEN** the user enters edit mode
- **THEN** the content field SHALL contain the raw Markdown source unchanged

#### Scenario: Images are never fetched

- **GIVEN** a note whose content contains `![tracker](https://example.com/pixel.png)`
- **WHEN** the note is open in view mode
- **THEN** the app SHALL NOT request the image URL and SHALL show the alt text in its place

### Requirement: Live presence and lock state are surfaced in the note view

While the note view is open the app SHALL display a presence indicator (list of viewers' actor names) and a lock indicator (current holder, if any) updated in real time from `presence` and `lock` WebSocket events. For three or fewer viewers the presence indicator SHALL show their names inline; beyond that it SHALL show a count, and SHALL always carry a tooltip listing every viewer's name. While the user holds the lock in edit mode, the app SHALL show an info banner naming the lock's expiry in local time, so it is clear the note is locked for others.

#### Scenario: Presence indicator updates on subscribe/unsubscribe

- **GIVEN** the note view is open
- **WHEN** another actor subscribes to or unsubscribes from the note
- **THEN** the presence indicator SHALL update to reflect the new viewer set

#### Scenario: Presence indicator names viewers inline

- **GIVEN** two actors, `cedric` and `agent-1`, are viewing the note
- **WHEN** the presence indicator renders
- **THEN** it SHALL show "cedric, agent-1" and a tooltip carrying the same names

#### Scenario: Presence indicator collapses to a count beyond three viewers

- **GIVEN** four actors are viewing the note
- **WHEN** the presence indicator renders
- **THEN** it SHALL show "4 viewers" with a tooltip listing all four names

#### Scenario: Lock indicator updates on lock event

- **WHEN** the server emits a `lock` event for the open note
- **THEN** the lock indicator SHALL update to show the new holder or "unlocked"

#### Scenario: Own-lock banner shows the expiry while editing

- **GIVEN** the user holds the lock and is in edit mode
- **WHEN** the note view renders
- **THEN** it SHALL show an info banner reading "You are editing (lock until HH:MM)" with the lock's expiry in local time

### Requirement: App provides a search view backed by /search

The app SHALL provide a search view that issues `GET /search?q=...` as the user types (debounced ~250ms) and renders titles, snippets (rendering `<mark>` markers as visual highlight), ranks, and each note's updated time (if the server returns `updated_at`). Tapping a result SHALL open that note in the note view. The field SHALL show a clear button while it holds text.

#### Scenario: Debounced search triggers request

- **GIVEN** the search view is open
- **WHEN** the user types `meet`
- **THEN** the app SHALL issue at most one `GET /search?q=meet` request after a ~250ms quiet period

#### Scenario: Empty input clears results

- **WHEN** the user empties the search field
- **THEN** the app SHALL clear results and SHALL NOT issue a request

#### Scenario: Clear button empties the field

- **GIVEN** the search field holds text
- **WHEN** the user taps the clear button
- **THEN** the app SHALL empty the field and the controller's query and SHALL return focus to the field

#### Scenario: Snippet markers are rendered as visual highlight

- **GIVEN** the server returns `snippet: "...the <mark>architecture</mark> doc..."`
- **WHEN** the result is rendered
- **THEN** the word `architecture` SHALL be visually emphasized (color, weight, or background)

#### Scenario: Results show a match count

- **GIVEN** a query returns three results
- **WHEN** the results render
- **THEN** the app SHALL show "3 matches" above the list (singular "1 match" for exactly one result)

#### Scenario: Empty results name the query

- **GIVEN** a query returns no results
- **WHEN** the empty state renders
- **THEN** the app SHALL show a message naming the query, for example `No matches for "meet".`

#### Scenario: Search error is shown to the user

- **GIVEN** the user types a query the server rejects (for example an unbalanced quote, which returns 400)
- **WHEN** the response arrives
- **THEN** the app SHALL display the server's `message` (or a generic fallback); if results from an earlier query are still on screen they SHALL stay visible beneath the error

#### Scenario: A syntax error hints at the cause

- **GIVEN** the server rejects the query with HTTP 400
- **WHEN** the error renders
- **THEN** the app SHALL show a hint ("Check quotes and special characters.") below the error message, determined from the error's status rather than by inspecting the query text

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
