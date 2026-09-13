## MODIFIED Requirements

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a sidebar (or equivalent navigation panel on narrow screens) backed by `GET /notes/tree` that shows folders as an expandable/collapsible tree with each folder's note count, plus a "All notes" root entry. Selecting a folder SHALL scope the notes list to that folder. The tree SHALL refresh when a `changed` event with `action: "moved"`, `"created"`, or `"deleted"` is received, since any of the three can change which folders have notes in them. The sidebar SHALL also provide a "New folder" action that prompts for a folder path (pre-filled with the currently selected folder, if any) and calls `POST /notes/tree` (per `notes-api`), then re-fetches the tree on success so the new (possibly empty) folder appears immediately.

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

## ADDED Requirements

### Requirement: The notes list FAB offers note and folder creation

The notes list screen's floating action button SHALL present a menu of at least two actions: "New note" and "New folder", rather than immediately creating a note on tap. Both actions SHALL target the currently selected folder (`NotesListState.selectedPath`), falling back to the vault root when no folder is selected.

#### Scenario: FAB presents a menu instead of creating instantly

- **WHEN** the user taps the FAB on the notes list screen
- **THEN** the app SHALL present a menu with "New note" and "New folder" actions rather than creating a note immediately

#### Scenario: New note from the FAB targets the current folder

- **GIVEN** the sidebar has folder `Projects/Alpha` selected
- **WHEN** the user chooses "New note" from the FAB menu
- **THEN** the app SHALL create the note with `path: "Projects/Alpha"` and navigate to it in edit mode, exactly as today's direct-create flow does otherwise

#### Scenario: New folder from the FAB targets the current folder

- **GIVEN** the sidebar has folder `Projects` selected
- **WHEN** the user chooses "New folder" from the FAB menu, and confirms the pre-filled prompt
- **THEN** the app SHALL call `POST /notes/tree` with a path nested under `Projects` and, on success, re-fetch the tree so the new folder appears

#### Scenario: New note from the FAB at the vault root

- **GIVEN** no folder is selected (`selectedPath` is `null`)
- **WHEN** the user chooses "New note" from the FAB menu
- **THEN** the app SHALL create the note with `path: ""` (vault root), matching prior behavior
