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

The app SHALL provide a list view that pages through `GET /notes?sort=updated_desc`, optionally scoped to the currently selected folder via the `path` query parameter, showing each note's title and updated time in the device's local time zone in most-recently-updated-first order, and supports pull-to-refresh, an explicit refresh action, and infinite scroll via `next_cursor`. The list SHALL update in response to `changed` WebSocket events (including `action: "moved"`) without manual refresh, and SHALL re-fetch when the user returns from a note so edits show even when the realtime stream is unavailable. When a fetch fails the app SHALL surface the failure without hiding items that already loaded.

#### Scenario: Initial load fetches first page

- **WHEN** the user opens the notes list
- **THEN** the app SHALL request `GET /notes?sort=updated_desc` and render the returned items

#### Scenario: Refresh action re-fetches the list

- **GIVEN** the notes list is open
- **WHEN** the user activates the Refresh action in the app bar
- **THEN** the app SHALL request `GET /notes?sort=updated_desc` again and render the returned items

#### Scenario: Overlapping refreshes coalesce into one request

- **GIVEN** a refresh is already in flight (e.g. from pull-to-refresh)
- **WHEN** another refresh is requested before it completes (e.g. a stale-reconnect refetch)
- **THEN** the app SHALL NOT issue a second `GET /notes` and SHALL apply the single in-flight request's result to both callers

#### Scenario: Returning from a note refreshes the list

- **GIVEN** the user opened a note from the list and saved a new version
- **WHEN** the note view is closed
- **THEN** the list SHALL request `GET /notes?sort=updated_desc` again and show the note's new version and updated time

#### Scenario: Failed fetch shows a non-blocking error with retry

- **GIVEN** the list has already rendered items
- **WHEN** a refresh or page fetch fails
- **THEN** the app SHALL show an error strip above the list carrying the server's `message` (or a generic fallback) and a retry control, and the existing items SHALL remain visible
- **AND** activating retry SHALL re-issue `GET /notes?sort=updated_desc` and clear the strip on success

#### Scenario: Updated time is shown in local time

- **GIVEN** a note whose `updated_at` is `2026-09-12T10:28:00Z`
- **WHEN** the list renders on a device in UTC+2
- **THEN** the entry SHALL show `2026-09-12 12:28` with no UTC marker

#### Scenario: Live changed event updates the list

- **GIVEN** the notes list is open and subscribed to `*`
- **WHEN** the server broadcasts `{"type":"changed","note_id":"X","action":"updated",...}`
- **THEN** the entry for `X` SHALL move to the top of the list and SHALL display the updated metadata without manual refresh

#### Scenario: Live created event prepends a new entry

- **WHEN** a new note is created elsewhere and the WS broadcasts the `changed` event
- **THEN** a new list entry SHALL appear at the top of the list without manual refresh

#### Scenario: Live deleted event removes the entry

- **WHEN** a note is deleted elsewhere and the WS broadcasts the `changed` event
- **THEN** the entry for that note SHALL be removed from the list

#### Scenario: Live moved event updates or removes an entry based on the current folder

- **GIVEN** the list is scoped to folder `Projects/Alpha` and note X is currently shown
- **WHEN** the server broadcasts a `changed` event for X with `action: "moved"` and X's new path is outside `Projects/Alpha`
- **THEN** the app SHALL re-fetch and X SHALL no longer appear in the list

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

When the user opens a note, the app SHALL `GET /notes/{id}`, subscribe to its WS events, and acquire the editor lock before allowing edits. While editing, the app SHALL heartbeat the lock periodically. The app SHALL automatically save edits approximately 2 seconds after the user stops changing the title or content, using the same save path as an explicit save; this automatic save SHALL NOT run while the conflict view is shown, and SHALL resume once a conflict is resolved and editing continues. On save (automatic or explicit) the app SHALL `PUT /notes/{id}` with the version it last loaded. The app SHALL handle 409 by presenting a conflict view with the server's title and content beside the user's own, editable, title and content; the view SHALL mark the title when the two differ and SHALL mark the content lines each side has that the other does not. The user SHALL be able to take the server's version, or edit their own version in place and save it against the server's current version. The app SHALL handle 423 by switching to read-only mode and surfacing the lock holder.

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

#### Scenario: Edits are saved automatically after a pause in typing

- **GIVEN** the user is in edit mode
- **WHEN** approximately 2 seconds pass with no further change to the title or content
- **THEN** the app SHALL `PUT /notes/{id}` with the current edit buffers and `If-Match` from the last-loaded version, without any user action

#### Scenario: A new edit within the debounce window postpones the automatic save

- **GIVEN** the user is in edit mode and stopped typing less than 2 seconds ago
- **WHEN** the user types again before the automatic save fires
- **THEN** the pending automatic save SHALL be postponed to run 2 seconds after this latest change instead

#### Scenario: Automatic save does not run while the conflict view is shown

- **GIVEN** a save returned 409 and the conflict view is showing
- **WHEN** approximately 2 seconds pass
- **THEN** the app SHALL NOT `PUT /notes/{id}` automatically; saving only happens when the user chooses "Use server version" or "Save mine"

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
- **THEN** the app SHALL trigger the same close flow as tapping the close button

### Requirement: Save and lock outcomes are surfaced in the note view

The note view SHALL confirm a completed explicit save and SHALL show the server's message when an explicit save or lock acquisition fails, so the user is never left silently in the editor after taking an explicit action. Outcomes the view already renders — 409 (conflict view) and 423 (lock banner) — SHALL NOT additionally produce a message. An automatic (debounced) save SHALL NOT produce a "Saved" confirmation message; its outcome is reflected only by the editing-status indicator, so it never interrupts typing. An automatic save that fails with neither 409 nor 423 SHALL also produce no message — the editing-status indicator showing "Unsaved changes" is sufficient, and the failure SHALL NOT block further typing.

#### Scenario: Successful save is confirmed

- **GIVEN** the user is editing a note
- **WHEN** the user taps "Save" (or the keyboard shortcut) and it returns 200 with version 7
- **THEN** the app SHALL show a brief "Saved (v7)" confirmation and stay in edit mode

#### Scenario: Failed save shows the server message

- **GIVEN** the user is editing a note
- **WHEN** the user taps "Save" and it fails with a status other than 409 or 423 (for example 400 for an empty title)
- **THEN** the app SHALL show a message containing the server's `message` and SHALL stay in edit mode with the edits intact

#### Scenario: Failed lock acquisition shows the server message

- **WHEN** `POST /notes/{id}/lock` fails with a status other than 423
- **THEN** the app SHALL show a message containing the server's `message` and remain read-only

#### Scenario: A successful automatic save shows no confirmation message

- **GIVEN** the user is editing a note
- **WHEN** the debounced automatic save returns 200
- **THEN** the app SHALL NOT show a "Saved" confirmation message; the editing-status indicator SHALL update instead

#### Scenario: A failed automatic save shows no error message

- **GIVEN** the user is editing a note
- **WHEN** the debounced automatic save fails with a status other than 409 or 423
- **THEN** the app SHALL NOT show an error message; the editing-status indicator SHALL show "Unsaved changes" and the user MAY continue typing or save explicitly

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

### Requirement: Realtime connection state is visible on every screen

The app SHALL show a strip above the routed content on every screen — list, note, and search alike — whenever the WebSocket connection is not established: "Reconnecting…" while the reconnect loop runs, and "Connection lost — showing cached notes" once the outage has lasted longer than the stale threshold. While connected, nothing SHALL be shown. Already-loaded content SHALL stay visible and usable throughout.

#### Scenario: Connected shows no indicator

- **GIVEN** the WS connection is established
- **WHEN** any screen renders
- **THEN** no connection strip SHALL be shown

#### Scenario: Short outage shows reconnecting

- **WHEN** the WS connection drops
- **THEN** every screen SHALL show "Reconnecting…" above its content until the connection is re-established

#### Scenario: Long outage marks the content as cached

- **WHEN** the WS connection has been down for more than the stale threshold
- **THEN** the strip SHALL read "Connection lost — showing cached notes" on every screen and SHALL stay until the connection is re-established

### Requirement: The app is routed by URL and supports deep links

The Flutter app SHALL use declarative, URL-addressable routes for its three screens: `/` (notes list), `/notes/{id}` (note view; a `edit=1` query parameter starts it in edit mode), and `/search`. On Web the app SHALL use the path URL strategy, so these routes appear as `/notes/{id}` rather than `/#/notes/{id}`, and reloading, bookmarking, or sharing any of these URLs SHALL restore the same screen. While no `AppConfig` is stored, every route SHALL show the first-run setup screen instead; once setup completes, the app SHALL continue to whichever location was originally requested.

#### Scenario: A note URL can be bookmarked and reloaded

- **GIVEN** the app is configured and note `01H` exists
- **WHEN** the user navigates the browser directly to `/notes/01H`
- **THEN** the app SHALL render that note's view, not the notes list

#### Scenario: An edit-mode URL opens the editor

- **WHEN** the user navigates directly to `/notes/01H?edit=1`
- **THEN** the app SHALL open note `01H` straight into the editor, as the create flow does

#### Scenario: A search URL renders the search screen

- **WHEN** the user navigates directly to `/search`
- **THEN** the app SHALL render the search screen

#### Scenario: An unconfigured deep link goes to setup first, then continues

- **GIVEN** the app has no saved configuration
- **WHEN** the user navigates directly to `/notes/01H`
- **THEN** the app SHALL show the setup screen
- **AND** once setup succeeds, the app SHALL continue on to `/notes/01H` rather than the notes list

#### Scenario: Closing a deep-linked note with no history returns to the list

- **GIVEN** the user navigated directly to a note URL (or reached it from search) with no prior screen on the navigation stack
- **WHEN** the user closes the note
- **THEN** the app SHALL go to `/`

#### Scenario: Closing a note opened from the list returns to the list

- **GIVEN** the user opened a note by tapping it in the notes list
- **WHEN** the user closes the note
- **THEN** the app SHALL return to the notes list rather than going to `/` from scratch

#### Scenario: Tapping a search result opens the note

- **GIVEN** the search screen shows a result for note `01H`
- **WHEN** the user taps it
- **THEN** the app SHALL navigate to `/notes/01H`

#### Scenario: The server serves the app shell for a reloaded client route

- **GIVEN** the app is deployed behind the bundled server
- **WHEN** a browser issues a plain `GET /notes/01H` or `GET /search` with no `Authorization` header
- **THEN** the server SHALL respond with the app's `index.html`, not the JSON API response for that path

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a sidebar (or equivalent navigation panel on narrow screens) backed by `GET /notes/tree` that shows folders as an expandable/collapsible tree with each folder's note count, plus a "All notes" root entry. Selecting a folder SHALL scope the notes list to that folder. The tree SHALL refresh when a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` is received, since any of the three can change which folders have notes in them.

#### Scenario: Tree renders folders from the server

- **GIVEN** `GET /notes/tree` returns folders `""`, `Projects/Alpha`, and `Projects/Beta`
- **WHEN** the sidebar loads
- **THEN** it SHALL render an expandable `Projects` node containing `Alpha` and `Beta`

#### Scenario: Selecting a folder scopes the list

- **WHEN** the user selects folder `Projects/Alpha` in the sidebar
- **THEN** the notes list SHALL request `GET /notes?path=Projects/Alpha`

#### Scenario: Tree updates after a live move

- **GIVEN** the sidebar is open
- **WHEN** a `changed` event with `action: "moved"` is received for any note
- **THEN** the app SHALL re-fetch `GET /notes/tree`

#### Scenario: Tree updates after a live delete empties a folder

- **GIVEN** the sidebar shows folder `Projects/Alpha` with one note in it
- **WHEN** a `changed` event with `action: "deleted"` is received for that note
- **THEN** the app SHALL re-fetch `GET /notes/tree` and `Projects/Alpha` SHALL no longer appear if it has no other notes

### Requirement: Note view supports moving a note to another folder

The note view SHALL provide an action to move the current note to a different folder, presenting the folder tree (from `GET /notes/tree`) or a free-text path entry, and submitting the change via `PUT /notes/{id}` with the new `path` and the current `If-Match` version. A `409 path_conflict` response SHALL be surfaced as a clear, non-destructive error naming the colliding path. A `423` response SHALL be surfaced as a locked-by-another-actor error, consistent with existing save-conflict handling.

#### Scenario: Move succeeds

- **WHEN** the user picks a target folder and confirms the move
- **THEN** the app SHALL send `PUT /notes/{id}` with the new `path` and, on success, SHALL update the open note's displayed folder

#### Scenario: Move conflict is surfaced without losing the note

- **WHEN** the move request returns `409 path_conflict`
- **THEN** the app SHALL show an error naming the conflict and SHALL leave the note open and unmoved

### Requirement: Editor offers link autocomplete and renders backlinks

While editing a note's content, typing `[[` SHALL open an autocomplete list of existing note titles (queried via `GET /search` or `GET /notes`), filtered as the user continues typing; selecting an entry SHALL insert `[[Title]]` (or `[[Title|Alias]]` if the user typed a pipe) at the cursor. The note view SHALL show a backlinks panel populated from `GET /notes/{id}/backlinks`, listing each referencing note's title and a snippet, and tapping an entry SHALL open that note.

#### Scenario: Typing [[ opens autocomplete

- **GIVEN** the user is editing a note and notes titled `Project Alpha` and `Project Beta` exist
- **WHEN** the user types `[[Proj`
- **THEN** the autocomplete list SHALL show both matching titles

#### Scenario: Selecting an autocomplete entry inserts a link

- **WHEN** the user selects `Project Alpha` from the autocomplete list
- **THEN** the editor content SHALL contain `[[Project Alpha]]` at the insertion point

#### Scenario: Backlinks panel lists referencing notes

- **GIVEN** note B links to the currently open note A
- **WHEN** the note view for A loads
- **THEN** the backlinks panel SHALL list note B with a snippet

#### Scenario: Empty backlinks panel is shown as empty state

- **GIVEN** no note links to the currently open note
- **WHEN** the note view loads
- **THEN** the backlinks panel SHALL show an empty-state message rather than an error

### Requirement: Tags are visible and filterable in the UI

The note view SHALL display the note's computed tags (per `notes-storage`) as chips. The notes list SHALL provide a way to filter by tag (e.g. tapping a chip, or a tag browser backed by `GET /tags`), applying the `tag` query parameter to `GET /notes`.

#### Scenario: Note view shows tag chips

- **GIVEN** a note's computed tags are `urgent` and `planning`
- **WHEN** the note view loads
- **THEN** it SHALL display chips for `urgent` and `planning`

#### Scenario: Tapping a tag filters the notes list

- **WHEN** the user taps the `urgent` chip
- **THEN** the notes list SHALL request `GET /notes?tag=urgent` and show only matching notes

### Requirement: Editor flushes pending edits when closing

When the user leaves the note view — via the close button, the browser back button, or the OS back gesture — while the edit buffers differ from the loaded note, the app SHALL attempt an immediate save before leaving, instead of asking for confirmation. Leaving with unchanged buffers SHALL NOT trigger a save. The outcome of that flush determines whether the note view actually closes.

#### Scenario: Leaving with a pending edit saves it and closes

- **GIVEN** the user is editing a note and has changed the title or content
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL `PUT /notes/{id}` immediately, and on success SHALL release the lock and leave the note view

#### Scenario: Leaving without edits does not trigger a save

- **GIVEN** the user is editing but the buffers match the loaded note
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL NOT `PUT /notes/{id}`, and SHALL release the lock and leave immediately

#### Scenario: A flush that hits a conflict keeps the note open

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save returns 409
- **THEN** the app SHALL present the conflict view and SHALL NOT leave the note view

#### Scenario: A flush that hits a transient error keeps the note open

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save fails with a status other than 409 or 423
- **THEN** the app SHALL show a message containing the server's `message`, SHALL keep the edits intact, and SHALL NOT leave the note view

#### Scenario: A flush that loses the lock still closes

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save fails with 423 because another actor took the lock
- **THEN** the app SHALL switch to read-only mode, drop the local edits, and leave the note view, consistent with losing the lock during any other save

### Requirement: Editing status indicator shows save state at a glance

While editing, the note view SHALL show who is editing and whether their most recent change has been saved, without requiring the user to open a menu.

#### Scenario: A save in flight shows "Saving…"

- **GIVEN** the user is editing a note
- **WHEN** a save (automatic or explicit) is in flight
- **THEN** the editing status SHALL read "Saving…"

#### Scenario: A pending, not-yet-saved edit shows "Unsaved changes"

- **GIVEN** the user is editing a note
- **WHEN** the edit buffers differ from the last-saved note and no save is currently in flight
- **THEN** the editing status SHALL read "Unsaved changes"

#### Scenario: A saved note shows when it was last saved

- **GIVEN** the user is editing a note
- **WHEN** the edit buffers match the last-saved note
- **THEN** the editing status SHALL read "Autosaved" followed by the last-saved time

