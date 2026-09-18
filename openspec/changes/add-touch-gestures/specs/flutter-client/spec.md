## ADDED Requirements

### Requirement: Note view can be pulled to re-fetch the note

While the note view is in read-only viewing mode, pulling the content down SHALL re-fetch `GET /notes/{id}` and the note's backlinks and render the result, without re-subscribing to the note's realtime events. The gesture SHALL NOT be offered while the note is being edited, while a conflict is shown, or while the lock is being acquired. A failed re-fetch SHALL surface the failure and keep the previously loaded note on screen.

#### Scenario: Pull-to-refresh re-fetches the note

- **GIVEN** the note view is showing note `X` at version 1 in viewing mode
- **WHEN** the user pulls the content down past the refresh threshold
- **THEN** the app SHALL request `GET /notes/X` again and render the returned title, content, and metadata

#### Scenario: Pull-to-refresh is not offered while editing

- **GIVEN** the user is editing note `X`
- **WHEN** they drag the editor content down
- **THEN** no refresh indicator SHALL appear and no `GET /notes/X` SHALL be issued

#### Scenario: Failed re-fetch keeps the note

- **GIVEN** the note view is showing note `X`
- **WHEN** the user pulls to refresh and the server responds with an error
- **THEN** the app SHALL surface the failure and `X`'s previously loaded content SHALL remain visible

## MODIFIED Requirements

### Requirement: Notes list can delete a note after confirmation

The list view SHALL offer a "Delete note" action on each entry, opened via long-press or (on desktop/web) right-click, and SHALL also reach the same action when the entry is swiped from its trailing edge toward its leading edge past the dismiss threshold. Choosing it SHALL ask the user to confirm before anything is sent. On confirmation the app SHALL `DELETE /notes/{id}`, remove the entry from the list, and show a brief "Note deleted" confirmation. A 404 from the server SHALL be treated as success, since the note is gone either way. Any other error SHALL keep the entry in the list and surface the failure. A swipe that is cancelled, or whose delete fails, SHALL return the entry to its resting position. Swiping an entry from its leading edge toward its trailing edge SHALL do nothing.

#### Scenario: Delete with confirmation

- **GIVEN** the notes list is open
- **WHEN** the user long-presses (or right-clicks) an entry, chooses "Delete note", and confirms
- **THEN** the app SHALL `DELETE /notes/{id}`, remove the entry from the list, and show "Note deleted"

#### Scenario: Swipe to delete with confirmation

- **GIVEN** the notes list is open
- **WHEN** the user swipes an entry from its trailing edge toward its leading edge past the dismiss threshold and confirms
- **THEN** the app SHALL `DELETE /notes/{id}`, remove the entry from the list, and show "Note deleted"

#### Scenario: Cancelling a swipe-to-delete restores the entry

- **GIVEN** the delete confirmation is showing because an entry was swiped
- **WHEN** the user cancels
- **THEN** no request SHALL be sent and the entry SHALL return to its resting position in the list

#### Scenario: A leading-to-trailing swipe does nothing

- **GIVEN** the notes list is open
- **WHEN** the user swipes an entry from its leading edge toward its trailing edge
- **THEN** no confirmation SHALL be shown and no request SHALL be sent

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

### Requirement: App provides a search view backed by /search

The app SHALL provide a search view that issues `GET /search?q=...` as the user types (debounced ~250ms) and renders titles, snippets (rendering `<mark>` markers as visual highlight), ranks, and each note's updated time (if the server returns `updated_at`). Tapping a result SHALL open that note in the note view. The view SHALL be a chrome-less surface headed by a row holding a search icon, the query field, a clear button while the field holds text, and a close button, rather than an app bar of its own. On compact windows it SHALL be presented as a top sheet; on medium and wider windows it SHALL be presented as a centered palette dialog no wider than 640 logical pixels, aligned toward the top of the window. Before the user has typed a query, the view SHALL show a "Recent" section listing recently-updated notes instead of a bare prompt, falling back to a plain "Type to search." message only when there are no notes to show. On a compact window the search sheet SHALL show a grab handle along its bottom edge and SHALL dismiss when swiped upward over the handle or the header, leaving the screen beneath it as it was; swiping over the results SHALL scroll them instead.

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

#### Scenario: Swiping the compact search sheet up dismisses it

- **GIVEN** the search sheet is open on a compact window
- **WHEN** the user drags the sheet's grab handle upward past the dismiss threshold
- **THEN** the sheet SHALL close, the notes list beneath it SHALL be unchanged, and no `GET /notes` SHALL be re-issued

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a sidebar backed by `GET /notes/tree` that shows folders as an expandable/collapsible tree with each folder's note count, plus a "All notes" root entry. On compact windows the sidebar SHALL open as a drawer from the "Folders" bottom-navigation destination and from a drag that starts at the leading screen edge; on medium and wider windows it SHALL be an inline panel beside the list whose width the user can drag; on large windows it SHALL be the first pane of the three-pane shell. Selecting a folder SHALL scope the notes list to that folder, which the list reflects in its title and folder filter chip. The tree SHALL refresh when a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` is received, since any of the three can change which folders have notes in them.

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

#### Scenario: Edge drag opens the folder drawer on a compact window

- **GIVEN** the notes list is open on a compact window with a folder panel
- **WHEN** the user drags from the leading screen edge toward the center
- **THEN** the folder drawer SHALL open
