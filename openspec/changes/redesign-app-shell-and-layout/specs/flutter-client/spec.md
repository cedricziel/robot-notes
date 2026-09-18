## ADDED Requirements

### Requirement: App layout adapts by window size class

The app SHALL classify the window width into four Material 3 window size classes — compact (narrower than 600 logical pixels), medium (600 or wider), expanded (840 or wider), and large (1200 or wider) — and every width-dependent layout decision SHALL be taken from that classification rather than from a per-screen pixel constant. Compact windows SHALL use phone chrome: bottom navigation, a floating action menu, the folder tree in a drawer, and search as a top sheet. Medium and wider windows SHALL use wide chrome: toolbar actions in place of the floating action menu, an inline, resizable folder sidebar, and search as a centered palette. Large windows SHALL render a three-pane shell — folder sidebar, notes list, and the open note side by side — in which `/` shows a "Select a note" placeholder in the note pane; below large, opening a note SHALL push it as a full-screen page over the list. A pane rendered inside the shell SHALL classify by its own width, not the window's.

#### Scenario: A compact window uses phone chrome

- **GIVEN** the window is 400 logical pixels wide
- **WHEN** the notes list renders
- **THEN** it SHALL show a bottom navigation bar and a floating action menu, SHALL NOT show toolbar actions, and SHALL open the folder tree in a drawer

#### Scenario: A medium window uses wide chrome

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the notes list renders
- **THEN** it SHALL show a toolbar with a labelled "New note" action and an inline folder sidebar, and SHALL NOT show a floating action button or bottom navigation

#### Scenario: A large window shows three panes

- **GIVEN** the window is 1400 logical pixels wide
- **WHEN** the app is at `/`
- **THEN** it SHALL render the folder sidebar, the notes list, and a "Select a note" placeholder side by side

#### Scenario: Opening a note in the shell fills the note pane

- **GIVEN** the window is 1400 logical pixels wide and the notes list shows note `01H`
- **WHEN** the user taps `01H`
- **THEN** the URL SHALL become `/notes/01H`, the note SHALL render in the third pane with a close control, and the list SHALL stay visible with the `01H` row highlighted

#### Scenario: Opening a note below large pushes a page

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the user taps a note in the list
- **THEN** the note SHALL cover the list as a full-screen page with a back arrow, and going back SHALL return to the list

#### Scenario: Resizing across the large threshold keeps the open note

- **GIVEN** the window is 1400 logical pixels wide with `/notes/01H` open in the note pane
- **WHEN** the window shrinks to 1000 logical pixels
- **THEN** the URL SHALL remain `/notes/01H` and the note SHALL render as a full-screen page

#### Scenario: The sidebar width is adjustable on wide layouts

- **GIVEN** the window is 800 logical pixels or wider
- **WHEN** the user drags the sidebar's resize handle
- **THEN** the sidebar SHALL follow the drag, clamped between 200 and 420 logical pixels

### Requirement: Account surface

The app SHALL provide an account surface reachable from the "Account" bottom-navigation destination on compact windows and from the toolbar's account button on wider windows, presented as a bottom sheet on compact windows and as a dialog otherwise. It SHALL show the configured server URL, the actor display name, and the current realtime connection state, and SHALL offer a "Disconnect" action. Disconnecting SHALL ask for confirmation before clearing the stored configuration and returning to the setup screen. The primary toolbar SHALL NOT carry a direct disconnect control.

#### Scenario: Opening the account surface shows the connection details

- **GIVEN** the app is configured for `https://notes.example.com` as actor `cedric`
- **WHEN** the user activates the Account destination or toolbar button
- **THEN** the account surface SHALL show `https://notes.example.com`, `cedric`, and the current connection state, without prompting to disconnect

#### Scenario: Disconnect asks for confirmation

- **GIVEN** the account surface is open
- **WHEN** the user taps "Disconnect" and confirms
- **THEN** the app SHALL clear the stored configuration and show the setup screen

#### Scenario: Cancelling the disconnect keeps the session

- **GIVEN** the disconnect confirmation is showing
- **WHEN** the user cancels
- **THEN** the configuration SHALL remain stored and the app SHALL stay on the notes list

#### Scenario: The toolbar has no logout button

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the notes list toolbar renders
- **THEN** it SHALL show an account button and SHALL NOT show a logout or disconnect icon

### Requirement: Keyboard shortcuts

The app SHALL bind Cmd (macOS) or Ctrl (other platforms) plus `N` to creating a note in the currently selected folder, and Cmd/Ctrl+`K` and Cmd/Ctrl+Shift+`F` to opening the search overlay, from the notes list and from an open note. The note view SHALL bind Cmd/Ctrl+`E` to entering edit mode while the note is read-only and not locked by another actor; Cmd/Ctrl+`S` (save) and Escape (close) keep their existing meaning. Escape SHALL also close the search overlay and the account surface.

#### Scenario: Cmd+N creates a note in the selected folder

- **GIVEN** the notes list is scoped to `Projects/Alpha`
- **WHEN** the user presses Cmd+N (macOS) or Ctrl+N (other platforms)
- **THEN** the app SHALL `POST /notes` with `path: "Projects/Alpha"` and open the new note in edit mode, exactly as the "New note" action does

#### Scenario: Cmd+K opens search

- **GIVEN** the notes list is open
- **WHEN** the user presses Cmd+K or Ctrl+K
- **THEN** the search overlay SHALL open with its field focused

#### Scenario: Cmd+Shift+F opens search

- **GIVEN** a note is open
- **WHEN** the user presses Cmd+Shift+F or Ctrl+Shift+F
- **THEN** the search overlay SHALL open above the note

#### Scenario: Cmd+E enters edit mode

- **GIVEN** a note is open in read-only mode and nobody holds its lock
- **WHEN** the user presses Cmd+E or Ctrl+E
- **THEN** the app SHALL `POST /notes/{id}/lock` and enter edit mode, exactly as the Edit button does

#### Scenario: Cmd+E does nothing while another actor holds the lock

- **GIVEN** a note is open read-only because another actor holds the lock
- **WHEN** the user presses Cmd+E or Ctrl+E
- **THEN** the app SHALL NOT send a lock request and the view SHALL stay read-only

#### Scenario: Escape closes the search overlay

- **GIVEN** the search overlay is open
- **WHEN** the user presses Escape
- **THEN** the overlay SHALL close and the screen underneath SHALL remain as it was

### Requirement: Notes list shows an empty state

When the first page of the notes list has loaded with no items and no error, the list SHALL show an empty state instead of a blank area. Unscoped, it SHALL read "No notes yet" and offer a "New note" action. Scoped to a folder, it SHALL read "Nothing in <folder>" and offer a "New note" action that creates the note in that folder. Scoped to a tag, it SHALL read "No notes tagged #<tag>" and offer a "Clear filter" action. While the first page is still loading the list SHALL show progress, not an empty state, and a failed first fetch SHALL show the error strip, not an empty state.

#### Scenario: An empty vault invites the first note

- **GIVEN** `GET /notes?sort=updated_desc` returns no items
- **WHEN** the notes list renders
- **THEN** it SHALL show "No notes yet" with a "New note" action that creates a note at the vault root

#### Scenario: An empty folder names the folder

- **GIVEN** the list is scoped to `Projects/Alpha` and the server returns no items for it
- **WHEN** the notes list renders
- **THEN** it SHALL show "Nothing in Alpha" with a "New note" action that creates the note in `Projects/Alpha`

#### Scenario: An empty tag filter offers to clear it

- **GIVEN** the list is filtered by tag `urgent` and the server returns no items
- **WHEN** the notes list renders
- **THEN** it SHALL show "No notes tagged #urgent" with a "Clear filter" action that removes the tag filter

#### Scenario: Loading and errors do not show an empty state

- **GIVEN** the first page is still loading, or the first fetch failed
- **WHEN** the notes list renders
- **THEN** it SHALL show a progress indicator or the error strip respectively, and SHALL NOT show an empty state

### Requirement: Status strips are consistent

Every inline banner in the app — the realtime connection state, fetch and search errors, the lock and editing-status banners in the note view, and setup failures — SHALL be rendered by one shared strip component with info, warning, and error tones whose colours come from the theme's colour scheme, so the same kind of message looks the same on every screen. No banner or status icon SHALL use a hard-coded colour. The connection strip SHALL be inset once below the platform status bar, and the app bar of the screen beneath it SHALL NOT inset a second time.

#### Scenario: Errors look the same on every screen

- **GIVEN** a notes-list fetch and a search request both fail
- **WHEN** their error strips render
- **THEN** both SHALL use the error tone from the colour scheme with the same shape and padding

#### Scenario: A setup failure uses the shared strip

- **GIVEN** the setup screen's validation request fails
- **WHEN** the error renders
- **THEN** it SHALL appear as an error-tone strip above the form rather than a screen-local banner

#### Scenario: The reachable indicator uses the colour scheme

- **GIVEN** the setup screen's reachability probe succeeded
- **WHEN** the reachable icon renders
- **THEN** its colour SHALL come from the colour scheme and SHALL NOT be a hard-coded green

#### Scenario: The connection strip insets once

- **GIVEN** the device has a status bar and the WebSocket is reconnecting
- **WHEN** the connection strip shows above the notes list
- **THEN** the strip SHALL sit below the status bar and the notes list's app bar SHALL sit directly below the strip with no extra top inset

## MODIFIED Requirements

### Requirement: Notes list view shows server state

The app SHALL provide a list view that pages through `GET /notes?sort=updated_desc`, optionally scoped to the currently selected folder via the `path` query parameter, showing each note's title and updated time in the device's local time zone in most-recently-updated-first order, and supports pull-to-refresh, an explicit refresh action, and infinite scroll via `next_cursor`. The list's title SHALL read "Notes" when unscoped, the selected folder's last path segment when scoped to a folder, and "Root" when scoped to the vault root, and the active folder scope SHALL also appear as a clearable filter chip beside the tag chip. Each row SHALL show the note's tags as plain text labels and its folder path in the metadata line together with the relative updated time; the path SHALL be omitted when the list is already scoped to that folder. On medium and wider windows the toolbar SHALL offer "New note", "Upload file", search, refresh, and account actions; on compact windows "Upload file" stays in the floating action menu. Inside the three-pane shell the row for the open note SHALL be highlighted. The list SHALL update in response to `changed` WebSocket events (including `action: "moved"`) without manual refresh, and SHALL re-fetch when the user returns from a note so edits show even when the realtime stream is unavailable. When a fetch fails the app SHALL surface the failure without hiding items that already loaded.

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
- **AND** the device's current time is `2026-10-01T09:00:00Z`, more than a week later
- **WHEN** the list renders on a device in UTC+2
- **THEN** the entry's metadata line SHALL show `2026-09-12 12:28` with no UTC marker

#### Scenario: Recent updates are shown relative to now

- **GIVEN** a note whose `updated_at` is three hours before the device's current time
- **WHEN** the list renders
- **THEN** the entry's metadata line SHALL show `3 hours ago` rather than an absolute timestamp

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

#### Scenario: The title reflects the folder scope

- **GIVEN** the user selected folder `Projects/Alpha` in the sidebar
- **WHEN** the notes list renders
- **THEN** its title SHALL read "Alpha", and selecting "All notes" SHALL return the title to "Notes"

#### Scenario: The folder chip clears the scope

- **GIVEN** the list is scoped to `Projects/Alpha`
- **WHEN** the user clears the folder filter chip
- **THEN** the list SHALL request `GET /notes?sort=updated_desc` without a `path` parameter and the chip SHALL disappear

#### Scenario: Rows show tags as text and the path in the metadata line

- **GIVEN** an unscoped list containing a note at `Projects/Alpha` tagged `urgent`
- **WHEN** its row renders
- **THEN** the row SHALL show `#urgent` as a text label (not a chip) and `Projects/Alpha` in the metadata line beside the relative updated time

#### Scenario: The path is hidden when the list is scoped to that folder

- **GIVEN** the list is scoped to `Projects/Alpha`
- **WHEN** a row for a note in `Projects/Alpha` renders
- **THEN** its metadata line SHALL show the relative updated time without repeating the folder path

#### Scenario: Upload file is reachable from the wide toolbar

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the user activates the toolbar's "Upload file" action and picks a file
- **THEN** the app SHALL `POST /notes/files` with the selected folder as `path`, exactly as the floating action menu's "Upload file" does on compact windows

#### Scenario: The open note's row is highlighted in the shell

- **GIVEN** the window is 1400 logical pixels wide and `/notes/01H` is open in the note pane
- **WHEN** the notes list pane renders
- **THEN** the row for `01H` SHALL be rendered as selected and no other row SHALL be

### Requirement: Note view renders the body as Markdown

In view mode the app SHALL render the note content as Markdown: headings, lists, emphasis, inline code, fenced code blocks, and links (styled; opening them is not yet supported). The rendered text SHALL be selectable. The metadata, body, tags, and backlinks SHALL form one scrolling reading column, capped to a comfortable line length and sharing one left edge, rather than a body that scrolls above a pinned footer. Double-tapping the body SHALL enter edit mode by the same path as the Edit action. Edit mode SHALL keep showing the raw Markdown source in a borderless, document-style text field capped to the same reading width, with a live preview that can be toggled; the preview SHALL default to shown on medium and wider windows and hidden on compact windows. The reading body and the preview SHALL use one Markdown stylesheet derived from the app theme, so the same source renders identically in both.

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

#### Scenario: The note reads as one column

- **GIVEN** a note with tags and backlinks is open in view mode
- **WHEN** the view renders
- **THEN** the metadata, body, tags, and backlinks SHALL scroll together in one column with the same left edge, and the backlinks SHALL NOT be pinned to the bottom of the screen

#### Scenario: Double-tapping the body enters edit mode

- **GIVEN** a note is open in read-only mode and nobody holds its lock
- **WHEN** the user double-taps the rendered body
- **THEN** the app SHALL `POST /notes/{id}/lock` and show the editor, exactly as the Edit action does

#### Scenario: The preview defaults from the window size

- **GIVEN** the user enters edit mode
- **WHEN** the window is 800 logical pixels wide
- **THEN** the live preview SHALL be shown beside or below the editor
- **WHEN** the window is 400 logical pixels wide
- **THEN** the live preview SHALL be hidden until the user toggles it on

#### Scenario: View and preview render identically

- **GIVEN** a note whose content is `# Heading` followed by a paragraph
- **WHEN** the same content is shown in the reading body and in the editor's preview
- **THEN** both SHALL apply the same heading and paragraph styles

### Requirement: Live presence and lock state are surfaced in the note view

While the note view is open the app SHALL display a presence indicator and a lock indicator (current holder, if any) updated in real time from `presence` and `lock` WebSocket events. The presence indicator SHALL render the viewers as a row of stacked avatars; for more than three viewers it SHALL show three avatars and an overflow count, and it SHALL always carry a tooltip listing every viewer's name. While the user holds the lock in edit mode, the app SHALL show an info banner naming the lock's expiry in local time, so it is clear the note is locked for others.

#### Scenario: Presence indicator updates on subscribe/unsubscribe

- **GIVEN** the note view is open
- **WHEN** another actor subscribes to or unsubscribes from the note
- **THEN** the presence indicator SHALL update to reflect the new viewer set

#### Scenario: Presence indicator names viewers inline

- **GIVEN** two actors, `cedric` and `agent-1`, are viewing the note
- **WHEN** the presence indicator renders
- **THEN** it SHALL show two stacked avatars and a tooltip reading "cedric, agent-1"

#### Scenario: Presence indicator collapses to a count beyond three viewers

- **GIVEN** four actors are viewing the note
- **WHEN** the presence indicator renders
- **THEN** it SHALL show three avatars plus an overflow count, with a tooltip listing all four names

#### Scenario: Lock indicator updates on lock event

- **WHEN** the server emits a `lock` event for the open note
- **THEN** the lock indicator SHALL update to show the new holder or "unlocked"

#### Scenario: Own-lock banner shows the expiry while editing

- **GIVEN** the user holds the lock and is in edit mode
- **WHEN** the note view renders
- **THEN** it SHALL show an info banner reading "You are editing (lock until HH:MM)" with the lock's expiry in local time

### Requirement: Editor offers link autocomplete and renders backlinks

While editing a note's content, typing `[[` SHALL open an autocomplete list of existing note titles (queried via `GET /search` or `GET /notes`), filtered as the user continues typing; selecting an entry SHALL insert `[[Title]]` (or `[[Title|Alias]]` if the user typed a pipe) at the cursor. The note view SHALL show a backlinks section populated from `GET /notes/{id}/backlinks`, listing each referencing note's title and a snippet, and tapping an entry SHALL open that note. The backlinks section SHALL be part of the note's scrolling reading column, after the tags, rather than a footer pinned below the body.

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

#### Scenario: Backlinks scroll with the note

- **GIVEN** a long note with backlinks is open in view mode
- **WHEN** the view first renders
- **THEN** the backlinks SHALL be below the body and tags in the same scrollable, reached by scrolling, and SHALL NOT occupy fixed space at the bottom of the screen

### Requirement: App provides a search view backed by /search

The app SHALL provide a search view that issues `GET /search?q=...` as the user types (debounced ~250ms) and renders titles, snippets (rendering `<mark>` markers as visual highlight), ranks, and each note's updated time (if the server returns `updated_at`). Tapping a result SHALL open that note in the note view. The view SHALL be a chrome-less surface headed by a row holding a search icon, the query field, a clear button while the field holds text, and a close button, rather than an app bar of its own. On compact windows it SHALL be presented as a top sheet; on medium and wider windows it SHALL be presented as a centered palette dialog no wider than 640 logical pixels, aligned toward the top of the window. Before the user has typed a query, the view SHALL show a "Recent" section listing recently-updated notes instead of a bare prompt, falling back to a plain "Type to search." message only when there are no notes to show.

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

#### Scenario: Recent notes fill the pre-query state

- **GIVEN** the search view has just opened and the user has not typed anything
- **AND** the caller has notes to show as recent
- **THEN** the app SHALL show a "Recent" section listing those notes, most-recently-updated-first, instead of the plain search hint

#### Scenario: No recent notes falls back to the plain hint

- **GIVEN** the search view has just opened with no notes to show as recent
- **THEN** the app SHALL show the "Type to search." message

#### Scenario: Typing replaces the Recent section

- **GIVEN** the Recent section is showing
- **WHEN** the user types a query
- **THEN** the Recent section SHALL be replaced by search results (or the empty/error state for that query)

#### Scenario: Search is a top sheet on a compact window

- **GIVEN** the window is 400 logical pixels wide
- **WHEN** the user opens search
- **THEN** the search view SHALL slide in from the top over a scrim, spanning the window's width, with no app bar of its own

#### Scenario: Search is a centered palette on a wider window

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the user opens search
- **THEN** the search view SHALL appear as a centered dialog no wider than 640 logical pixels, positioned toward the top of the window, with the query field focused

#### Scenario: The header's close button dismisses search

- **GIVEN** the search view is open
- **WHEN** the user taps the close button in its header
- **THEN** the overlay SHALL close and the screen underneath SHALL remain as it was

### Requirement: The app is routed by URL and supports deep links (notes only)

The Flutter app SHALL use declarative, URL-addressable routes for its two screens: `/` (notes list) and `/notes/{id}` (note view; a `edit=1` query parameter starts it in edit mode). Both routes SHALL be rendered inside one shell so that, on large windows, `/` shows the folder sidebar, the notes list, and a "Select a note" placeholder side by side and `/notes/{id}` shows the same sidebar and list with the note in the third pane; below large, `/` is the full-screen list and `/notes/{id}` is a page pushed over it. Search SHALL be presented as an overlay above the current screen rather than a distinct route, and is not independently URL-addressable. On Web the app SHALL use the path URL strategy, so these routes appear as `/notes/{id}` rather than `/#/notes/{id}`, and reloading, bookmarking, or sharing either of these URLs SHALL restore the same screen. While no `AppConfig` is stored, every route SHALL show the first-run setup screen instead; once setup completes, the app SHALL continue to whichever location was originally requested.

#### Scenario: A note URL can be bookmarked and reloaded

- **GIVEN** the app is configured and note `01H` exists
- **WHEN** the user navigates the browser directly to `/notes/01H`
- **THEN** the app SHALL render that note's view, not the notes list

#### Scenario: A note URL reloaded in a large window restores the three panes

- **GIVEN** the app is configured, note `01H` exists, and the window is 1400 logical pixels wide
- **WHEN** the user navigates the browser directly to `/notes/01H`
- **THEN** the app SHALL render the sidebar, the notes list with `01H` highlighted, and the note in the third pane

#### Scenario: An edit-mode URL opens the editor

- **WHEN** the user navigates directly to `/notes/01H?edit=1`
- **THEN** the app SHALL open note `01H` straight into the editor, as the create flow does

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

- **GIVEN** the user opened a note by tapping it in the notes list on a window narrower than 1200 logical pixels
- **WHEN** the user closes the note
- **THEN** the app SHALL return to the notes list rather than going to `/` from scratch

#### Scenario: Closing a note in the shell empties the note pane

- **GIVEN** the window is 1400 logical pixels wide and `/notes/01H` is open in the note pane
- **WHEN** the user closes the note
- **THEN** the URL SHALL become `/`, the note pane SHALL show the "Select a note" placeholder, and the sidebar and list SHALL stay where they were

#### Scenario: Opening search does not change the URL

- **GIVEN** the user is on the notes list
- **WHEN** the user opens the search overlay
- **THEN** the reported URL SHALL stay unchanged, and the notes list SHALL remain mounted underneath

#### Scenario: Tapping a search result opens the note

- **GIVEN** the search overlay shows a result for note `01H`
- **WHEN** the user taps it
- **THEN** the app SHALL close the overlay and navigate to `/notes/01H`

#### Scenario: The server serves the app shell for a reloaded client route

- **GIVEN** the app is deployed behind the bundled server
- **WHEN** a browser issues a plain `GET /notes/01H` with no `Authorization` header
- **THEN** the server SHALL respond with the app's `index.html`, not the JSON API response for that path

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a sidebar backed by `GET /notes/tree` that shows folders as an expandable/collapsible tree with each folder's note count, plus a "All notes" root entry. On compact windows the sidebar SHALL open as a drawer from the "Folders" bottom-navigation destination; on medium and wider windows it SHALL be an inline panel beside the list whose width the user can drag; on large windows it SHALL be the first pane of the three-pane shell. Selecting a folder SHALL scope the notes list to that folder, which the list reflects in its title and folder filter chip. The tree SHALL refresh when a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` is received, since any of the three can change which folders have notes in them.

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

#### Scenario: The sidebar is a drawer on a compact window

- **GIVEN** the window is 400 logical pixels wide
- **WHEN** the user activates the "Folders" bottom-navigation destination
- **THEN** the folder tree SHALL open in a drawer, and selecting a folder SHALL close the drawer and scope the list

#### Scenario: The sidebar is an inline, resizable panel on a wider window

- **GIVEN** the window is 800 logical pixels wide
- **WHEN** the notes list renders
- **THEN** the folder tree SHALL be shown inline beside the list with a resize handle, and no "Folders" bottom-navigation destination SHALL be shown

### Requirement: Realtime connection state is visible on every screen

The app SHALL show a strip above the routed content on every screen — list, note, and search alike — whenever the WebSocket connection is not established: "Reconnecting…" while the reconnect loop runs, and "Connection lost — showing cached notes" once the outage has lasted longer than the stale threshold. The strip SHALL be the shared status strip in its warning and error tones respectively, inset once below the platform status bar. While connected, nothing SHALL be shown and no space SHALL be reserved. Already-loaded content SHALL stay visible and usable throughout.

#### Scenario: Connected shows no indicator

- **GIVEN** the WS connection is established
- **WHEN** any screen renders
- **THEN** no connection strip SHALL be shown and the screen's app bar SHALL sit directly below the status bar

#### Scenario: Short outage shows reconnecting

- **WHEN** the WS connection drops
- **THEN** every screen SHALL show "Reconnecting…" in a warning-tone strip above its content until the connection is re-established

#### Scenario: Long outage marks the content as cached

- **WHEN** the WS connection has been down for more than the stale threshold
- **THEN** the strip SHALL read "Connection lost — showing cached notes" in an error-tone strip on every screen and SHALL stay until the connection is re-established

#### Scenario: The strip does not push the app bar down twice

- **GIVEN** the device has a status bar and the connection strip is showing
- **WHEN** the notes list renders beneath it
- **THEN** the list's app bar SHALL begin immediately below the strip, without a second status-bar-height gap

### Requirement: First-run flow captures server URL, API key, and actor name

On first launch (no saved configuration) the app SHALL present a setup screen requesting three values: server base URL, API key, and actor display name, laid out in a width-capped, centered card rather than stretching to the window width. The app SHALL validate the configuration by issuing an authenticated request (e.g. `GET /healthz` followed by `GET /notes?limit=1`) before persisting it. On validation failure the app SHALL display the error code from the server in the shared status strip and SHALL allow the user to correct and retry. While the user is entering the server URL, the app SHALL show a live, best-effort reachability indicator (checking / reachable / unreachable) next to the field, determined by a `GET /healthz` probe and coloured from the theme's colour scheme; this indicator is informational only and SHALL NOT gate proceeding.

#### Scenario: Successful setup persists configuration

- **GIVEN** the app has no saved configuration
- **WHEN** the user enters a valid URL, key, and name and submits
- **THEN** the app SHALL store all three in secure storage and proceed to the notes list

#### Scenario: Invalid key surfaces error

- **GIVEN** the app has no saved configuration
- **WHEN** the user enters an URL and a wrong key and submits
- **THEN** the app SHALL display an error referencing the 401 response in an error-tone status strip and SHALL not persist the configuration

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
- **THEN** the app SHALL show a reachable indicator next to the URL field, coloured from the colour scheme, without requiring the user to press Continue or Connect

#### Scenario: A live check surfaces an unreachable server before submitting

- **GIVEN** the user is entering the server URL
- **WHEN** the app's `GET /healthz` probe fails or times out after the user pauses typing
- **THEN** the app SHALL show an unreachable indicator next to the URL field, without disabling Continue

#### Scenario: A stale reachability check does not override a newer one

- **GIVEN** the user changed the URL again before an earlier reachability probe finished
- **WHEN** the earlier probe's response arrives after the newer probe's response
- **THEN** the app SHALL keep showing the newer probe's result
