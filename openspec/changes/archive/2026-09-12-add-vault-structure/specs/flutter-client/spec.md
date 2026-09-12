## MODIFIED Requirements

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

## ADDED Requirements

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
