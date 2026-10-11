## MODIFIED Requirements

### Requirement: Note view supports edit, lock, and concurrency UX

When the user opens a note, the app SHALL `GET /notes/{id}`, subscribe to its WS events, and automatically acquire the editor lock without an Edit action. After acquiring the lock and re-fetching the note, the app SHALL show the block editor. Until then, the note SHALL remain read-only. Opening an existing note SHALL NOT focus a field or summon the software keyboard. A failed acquisition SHALL show the existing error or lock-holder feedback and offer an explicit retry. While editing, the app SHALL heartbeat the lock periodically. The app SHALL automatically save edits approximately 2 seconds after the user stops changing the title or content, using the same save path as an explicit save; this automatic save SHALL NOT run while the conflict view is shown, and SHALL resume once a conflict is resolved and editing continues. On save (automatic or explicit) the app SHALL `PUT /notes/{id}` with the version it last loaded. The app SHALL handle 409 by presenting a conflict view with the server's title and content beside the user's own, editable, title and content; the view SHALL mark the title when the two differ and SHALL mark the content lines each side has that the other does not. The user SHALL be able to take the server's version, or edit their own version in place and save it against the server's current version. The app SHALL handle 423 by switching to read-only mode and surfacing the lock holder.

#### Scenario: Edit acquires the lock

- **WHEN** the user opens an existing note from the list, search, or a direct link
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
- **WHEN** they press Escape with no editor menu or transient selection UI open
- **THEN** the app SHALL trigger the same close flow as tapping the close button

### Requirement: A newly created note opens in edit mode

When the user creates a note from the list, the app SHALL open it straight into the editor: after `POST /notes` and `GET /notes/{id}` it SHALL acquire the lock, show the editor, focus the title field, and select the placeholder title so that typing replaces it. Opening an existing note SHALL also enter the block editor automatically after lock acquisition, without selecting its title.

#### Scenario: Create opens the editor with the title selected

- **WHEN** the user taps the create action and `POST /notes` succeeds
- **THEN** the app SHALL open the note, `POST /notes/{id}/lock`, and show the editor with the title field focused and its full text selected

#### Scenario: Lock unavailable on a new note

- **GIVEN** the lock request for the new note fails
- **WHEN** the note opens
- **THEN** the app SHALL fall back to the read-only view with the usual lock feedback

### Requirement: Note view renders the body as Markdown

In view mode the app SHALL render the note content as Markdown: headings, lists, emphasis, inline code, fenced code blocks, and links (styled; opening them is not yet supported). The rendered text SHALL be selectable. Edit mode SHALL show the block editor by default and offer an explicit Markdown source option in a plain text field. The source option SHALL expose the current draft, including unsaved edits. Neither editing presentation SHALL fetch Markdown image URLs.

#### Scenario: Markdown syntax is rendered, not shown verbatim

- **GIVEN** a note whose content is `# Heading`, a `- item` bullet, and `` `code` ``
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show "Heading" styled as a heading, "item" as a list entry, and "code" as inline code, and SHALL NOT show the `#`, `-`, or backtick markers

#### Scenario: Edit mode shows the Markdown source

- **WHEN** the user selects the Markdown source option
- **THEN** the content field SHALL contain the current Markdown draft without conversion loss

#### Scenario: Images are never fetched

- **GIVEN** a note whose content contains `![tracker](https://example.com/pixel.png)`
- **WHEN** the note is open in view mode
- **THEN** the app SHALL NOT request the image URL and SHALL show the alt text in its place

### Requirement: Database embeds render in view mode

In view mode, a line consisting of `![[Title]]` or `![[Title#View]]` where `Title` is the title of a registered database SHALL be rendered as an embedded, read-only rendering of that database's named view (or its default view): a header with the database title linking to `/databases/{id}?view=<name>` and rows rendered as a table for table and list views, or as columns for a board view, limited to the first 50 rows with a "Show all" link. Row titles SHALL link to their notes. The embed SHALL be resolved by matching `Title` against `GET /databases` titles case-insensitively after NFC normalisation. An embed whose title does not resolve, or whose view name does not exist, SHALL render the literal source text. The Markdown source option SHALL hold the literal source. The block editor SHALL preserve database embed source as an opaque block and display the existing read-only embed rendering when it resolves. Non-matching `[[...]]` and `![[...]]` text SHALL keep rendering as literal text, as today. Embedded rows SHALL refresh on `changed` events with the same debounce as the database screen. The embed SHALL render with bounded height inside the reading column and remain tappable within the surrounding selectable text.

#### Scenario: Embed renders the named view

- **GIVEN** a note body contains `![[Projects#Active]]` and a database titled `Projects` with a view `Active`
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show a table headed `Projects` with the rows of the `Active` view instead of the literal text

#### Scenario: Unknown title renders literally

- **GIVEN** a note body contains `![[Nothing Here]]` and no database has that title
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show the text `![[Nothing Here]]`

#### Scenario: Edit field keeps the literal text while the preview renders it

- **WHEN** the user selects Markdown source for a note containing `![[Projects#Active]]`
- **THEN** the source field SHALL contain the literal embed text without a simultaneous preview pane
- **AND** switching to Blocks SHALL display the embedded table while retaining the literal Markdown source
