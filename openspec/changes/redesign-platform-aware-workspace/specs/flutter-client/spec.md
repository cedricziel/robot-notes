## ADDED Requirements

### Requirement: Compact workspace destinations
The client SHALL provide Notes, Databases, Search and Settings destinations on
compact root workspaces. Destination changes SHALL preserve search input and
list state. Folder selection, creation and upload SHALL remain reachable by
buttons or menus. Opening a note SHALL retain guarded save-before-close behavior.

#### Scenario: Switch away from search and back
- **WHEN** a user enters a query, selects Databases, and returns to Search
- **THEN** the query remains present and results remain available.

### Requirement: Device-local appearance and layout
The client SHALL offer System, Light and Dark appearance choices and persist
the selected mode and wide sidebar width on the device. Invalid saved values
SHALL fall back or clamp to supported bounds.

#### Scenario: Restart with a saved appearance
- **WHEN** a new preferences controller loads a saved Dark mode
- **THEN** the app uses Dark mode independently of the server connection.

### Requirement: Accessible workspace controls
Search SHALL support arrow-key result selection and Enter activation. Sidebar
resize SHALL provide keyboard and assistive-technology increase/decrease actions.
Reading properties SHALL scroll with the document and support narrow layouts
and enlarged text.

#### Scenario: Resize using keyboard
- **WHEN** the resize handle has focus and the user presses Right Arrow
- **THEN** the sidebar expands within its configured maximum width.
