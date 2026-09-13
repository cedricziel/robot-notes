## MODIFIED Requirements

### Requirement: App provides a search view backed by /search

The app SHALL provide a search view that issues `GET /search?q=...` as the user types (debounced ~250ms) and renders titles, snippets (rendering `<mark>` markers as visual highlight), ranks, and each note's updated time (if the server returns `updated_at`). Tapping a result SHALL open that note in the note view. The field SHALL show a clear button while it holds text. Before the user has typed a query, the view SHALL show a "Recent" section listing recently-updated notes instead of a bare prompt, falling back to a plain "Type to search." message only when there are no notes to show.

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

## REMOVED Requirements

### Requirement: The app is routed by URL and supports deep links

**Reason**: Search is no longer a distinct route — it is presented as an overlay above the current screen (see the modified search requirement) and is not independently URL-addressable.

**Migration**: See the new requirement "The app is routed by URL and supports deep links (notes only)" below, which keeps every remaining route and deep-link scenario and adds a scenario for the overlay leaving the URL unchanged.

## ADDED Requirements

### Requirement: The app is routed by URL and supports deep links (notes only)

The Flutter app SHALL use declarative, URL-addressable routes for its two screens: `/` (notes list) and `/notes/{id}` (note view; a `edit=1` query parameter starts it in edit mode). Search SHALL be presented as an overlay above the current screen rather than a distinct route, and is not independently URL-addressable. On Web the app SHALL use the path URL strategy, so these routes appear as `/notes/{id}` rather than `/#/notes/{id}`, and reloading, bookmarking, or sharing either of these URLs SHALL restore the same screen. While no `AppConfig` is stored, every route SHALL show the first-run setup screen instead; once setup completes, the app SHALL continue to whichever location was originally requested.

#### Scenario: A note URL can be bookmarked and reloaded

- **GIVEN** the app is configured and note `01H` exists
- **WHEN** the user navigates the browser directly to `/notes/01H`
- **THEN** the app SHALL render that note's view, not the notes list

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

- **GIVEN** the user opened a note by tapping it in the notes list
- **WHEN** the user closes the note
- **THEN** the app SHALL return to the notes list rather than going to `/` from scratch

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
