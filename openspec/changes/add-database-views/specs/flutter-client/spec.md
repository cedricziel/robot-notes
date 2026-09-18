# Spec Delta

## ADDED Requirements

### Requirement: The app is routed to a database screen

The app SHALL add the route `/databases/{id}` rendering the database screen for that database, with an optional `view` query parameter naming the saved view to show; when absent or unknown, the default (first) view SHALL be shown. The route SHALL follow the same setup-redirect, deep-link, and close-to-list rules as `/notes/{id}`. The bundled server SHALL serve the app shell for a plain `GET /databases/{id}` without an `Authorization` header.

#### Scenario: Deep link opens a view

- **GIVEN** database `01D` has views `All` and `Kanban`
- **WHEN** the user navigates to `/databases/01D?view=Kanban`
- **THEN** the app SHALL render the board view of that database

#### Scenario: Unknown view falls back to the default

- **WHEN** the user navigates to `/databases/01D?view=Nope`
- **THEN** the app SHALL render the first view and replace the URL's `view` parameter with its name

### Requirement: Sidebar lists databases and can create one

The sidebar SHALL show a "Databases" section listing every entry from `GET /databases` by title, refreshed when a `changed` event with `action` `created`, `updated`, `moved`, or `deleted` arrives for a note that is a database, or when the database list has not been fetched since the last such event of any note. Selecting an entry SHALL navigate to `/databases/{id}`. The section SHALL offer a "New database" action opening a form with title, folder (selected from the folder tree or typed) or tag as the source, an initial property list (key, type, options for selects), and a first view (name, type, and for a board the grouping property). Submitting SHALL call `POST /databases` and navigate to the new database. Validation errors from the server SHALL be shown next to the form without closing it.

#### Scenario: Databases appear in the sidebar

- **GIVEN** `GET /databases` returns `Projects` and `Reading`
- **WHEN** the sidebar loads
- **THEN** it SHALL show a Databases section containing `Projects` and `Reading`

#### Scenario: Creating a database navigates to it

- **WHEN** the user submits the new-database form with title `Projects`, folder `Projects`, property `status` (select: Idea, Active, Done) and a table view `All`
- **THEN** the app SHALL `POST /databases` with that definition and, on 201, navigate to `/databases/{id}`

#### Scenario: Server validation error is shown inline

- **WHEN** `POST /databases` returns 400 `validation_failed` with a message naming `status`
- **THEN** the form SHALL stay open and show the message

### Requirement: Database screen renders saved views as table, list, or board

The database screen SHALL show the database title, a view switcher listing the saved views by name, a "New row" action, and a schema-editor action. It SHALL load rows via `POST /databases/{id}/query` with `{view: <name>}` and page through `next_cursor` as the user scrolls. It SHALL re-query when a `changed` event arrives for any note whose `path` or tags could make it a row (any `changed` event while the screen is open is sufficient), debounced to at most one query per second. A `table` view SHALL render one column per property in the view's `properties` list (or every declared property when the list is absent) plus a leading title column, with `invalid` values highlighted. A `list` view SHALL render one line per row with the title and the view's properties as compact chips. A `board` view SHALL render one column per option of the `group_by` property in option order, plus a trailing "No value" column, with the counts from `groups` in each column header and a card per row showing the title and the view's properties. Tapping a title, list row, or card SHALL navigate to `/notes/{id}`.

#### Scenario: Table renders view columns

- **GIVEN** a view `All` of type `table` with `properties: [status, due]`
- **WHEN** the screen shows `All`
- **THEN** the table SHALL have columns Title, Status, Due in that order and one row per returned item

#### Scenario: Board columns follow option order and show counts

- **GIVEN** a board grouped by `status` with options Idea, Active, Done and `groups` reporting 2, 3, 0 plus 1 with no value
- **WHEN** the screen shows the board
- **THEN** it SHALL render columns Idea (2), Active (3), Done (0), No value (1)

#### Scenario: Switching views updates the URL

- **WHEN** the user selects the view `Kanban` in the switcher
- **THEN** the app SHALL query with `view: "Kanban"` and set the URL to `/databases/{id}?view=Kanban`

#### Scenario: Live change re-queries

- **GIVEN** the table view is open
- **WHEN** a `changed` event arrives for a row
- **THEN** the app SHALL re-run the query within about one second and update the rows in place without losing scroll position

#### Scenario: New row opens the editor

- **WHEN** the user taps "New row" and enters a title
- **THEN** the app SHALL `POST /databases/{id}/rows` with that title and navigate to `/notes/{id}?edit=1` for the created note

### Requirement: Table cells are editable inline and board cards move between columns

In a table view, tapping a property cell SHALL open the type-appropriate editor in place (text field, number field, checkbox toggle, date picker, select menu, multi-select chips, relation picker, url field) and committing SHALL call `PATCH /notes/{id}/properties` with `set` for the new value or `unset` when cleared. Built-in columns SHALL NOT be editable. A 400 `validation_failed` SHALL revert the cell and show the message. In a board view, dragging a card to another column SHALL patch the `group_by` property to that column's option, or `unset` it when dropped on "No value"; the card SHALL move optimistically and revert on error.

#### Scenario: Editing a select cell patches the note

- **GIVEN** a row with `status: Idea`
- **WHEN** the user picks `Active` in the cell's select menu
- **THEN** the app SHALL send `PATCH /notes/{id}/properties` with `{"set":{"status":"Active"}}` and the cell SHALL show `Active`

#### Scenario: Clearing a cell unsets the property

- **WHEN** the user clears a date cell
- **THEN** the app SHALL send `{"unset":["due"]}`

#### Scenario: Board drag patches the grouped property

- **GIVEN** a board grouped by `status`
- **WHEN** the user drags a card from Idea to Done
- **THEN** the app SHALL send `{"set":{"status":"Done"}}` and the card SHALL appear in the Done column

#### Scenario: Rejected edit reverts

- **WHEN** the patch returns 400
- **THEN** the cell SHALL show its previous value and the message SHALL be surfaced

### Requirement: Schema editor edits properties and views

The database screen SHALL provide a schema editor showing the definition from `GET /databases/{id}`: the source, the property list (key, label, type, options for selects, target database for relations), and the views (name, type, group_by, sort, filter, visible properties). The user SHALL be able to add and remove properties, change a property's label, type, and options, and add, edit, reorder, and delete views; a filter SHALL be edited as a list of conditions combined with and/or, matching the server filter grammar. Saving SHALL send `PUT /databases/{id}` with the full `properties` and `views` sections and `If-Match` set to the loaded version; a 409 SHALL reload the definition and ask the user to reapply. Property keys SHALL be validated client-side against `^[a-z][a-z0-9_]*$` before submission. Removing a property SHALL warn that row values are kept on disk but hidden.

#### Scenario: Adding a property

- **WHEN** the user adds property `due` of type `date` and saves
- **THEN** the app SHALL send `PUT /databases/{id}` whose `properties` includes `due: {type: date}` and the table SHALL gain a Due column

#### Scenario: Invalid key is blocked client-side

- **WHEN** the user types the key `Due Date`
- **THEN** the save action SHALL be disabled and the field SHALL show the key rule

#### Scenario: Stale save reloads

- **WHEN** `PUT /databases/{id}` returns 409
- **THEN** the app SHALL fetch the definition again, show the server's version, and keep the user's unsaved edits visible for reapplying

### Requirement: Note view shows and edits properties in a panel

The note view SHALL render a property panel above the body listing the note's `properties`. For a note covered by at least one database, each declared property SHALL be shown with its type-aware editor, in definition order; undeclared properties SHALL be shown as read-only key and value pairs. Editing a property SHALL call `PATCH /notes/{id}/properties` immediately on commit, independent of the body editor's lock and autosave, and SHALL NOT change the edit buffers or the `If-Match` baseline used for body saves except to adopt the new `version` returned. When a `changed` event arrives for the open note while the user is editing the body, the app SHALL refetch only the properties and refresh the panel without touching the title or content buffers. The panel SHALL be collapsible and collapsed state remembered per device.

#### Scenario: Declared properties use typed editors

- **GIVEN** the note is in folder `Projects` covered by a database declaring `status` (select) and `due` (date)
- **WHEN** the note view opens
- **THEN** the panel SHALL show a select for `status` and a date picker for `due`

#### Scenario: Property edit during body editing does not disturb the buffer

- **GIVEN** the user is in edit mode with unsaved body text
- **WHEN** the user changes `status` in the panel
- **THEN** the app SHALL send the property patch, the content field SHALL be unchanged, and the next body save SHALL use the version returned by the patch

#### Scenario: Live property change refreshes the panel only

- **GIVEN** the user is in edit mode
- **WHEN** a `changed` event for this note arrives after an agent patched `status`
- **THEN** the panel SHALL show the new `status` and the title and content fields SHALL be unchanged

### Requirement: Database embeds render in view mode

In view mode, a line consisting of `![[Title]]` or `![[Title#View]]` where `Title` is the title of a registered database SHALL be rendered as an embedded, read-only rendering of that database's named view (or its default view): a header with the database title linking to `/databases/{id}?view=<name>` and rows rendered as a table for table and list views, or as columns for a board view, limited to the first 50 rows with a "Show all" link. Row titles SHALL link to their notes. The embed SHALL be resolved by matching `Title` against `GET /databases` titles case-insensitively after NFC normalisation. An embed whose title does not resolve, or whose view name does not exist, SHALL render the literal source text. Embeds SHALL NOT be rendered in edit mode. Embedded rows SHALL refresh on `changed` events with the same debounce as the database screen.

#### Scenario: Embed renders the named view

- **GIVEN** a note body contains `![[Projects#Active]]` and a database titled `Projects` with a view `Active`
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show a table headed `Projects` with the rows of the `Active` view instead of the literal text

#### Scenario: Unknown title renders literally

- **GIVEN** a note body contains `![[Nothing Here]]` and no database has that title
- **WHEN** the note is open in view mode
- **THEN** the body SHALL show the text `![[Nothing Here]]`

#### Scenario: Embed is not rendered while editing

- **WHEN** the user enters edit mode
- **THEN** the content field SHALL contain the literal `![[Projects#Active]]`
