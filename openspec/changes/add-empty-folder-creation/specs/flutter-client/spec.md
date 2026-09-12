## MODIFIED Requirements

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a sidebar (or equivalent navigation panel on narrow screens) backed by `GET /notes/tree` that shows folders as an expandable/collapsible tree with each folder's note count, plus a "All notes" root entry. Selecting a folder SHALL scope the notes list to that folder. The tree SHALL refresh when a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` is received, since any of the three can change which folders have notes in them. The sidebar SHALL also provide a "New folder" action that prompts for a folder path and calls `POST /notes/tree` (per `notes-api`), then re-fetches the tree on success so the new (possibly empty) folder appears immediately.

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
- **THEN** the app SHALL re-fetch `GET /notes/tree` and `Projects/Alpha` SHALL no longer appear if it has no other notes and was never explicitly created as an empty folder

#### Scenario: Creating a new folder from the sidebar

- **WHEN** the user taps "New folder", enters `Ideas`, and confirms
- **THEN** the app SHALL call `POST /notes/tree` with `{ "path": "Ideas" }`
- **AND** on success SHALL re-fetch the tree so `Ideas` appears with a note count of zero

#### Scenario: Folder creation failure shows a real error

- **WHEN** `POST /notes/tree` fails
- **THEN** the app SHALL show the server's error message (falling back to a generic message when none is provided), not a raw or empty error, and SHALL NOT close the "New folder" prompt destructively
