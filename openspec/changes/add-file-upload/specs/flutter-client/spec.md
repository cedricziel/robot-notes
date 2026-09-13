## ADDED Requirements

### Requirement: The notes list FAB offers file upload

The notes list screen's floating action button menu SHALL include an "Upload file" action alongside "New note" and "New folder". Choosing it SHALL open the platform's native file picker; on a file being chosen, the app SHALL upload it to `POST /notes/attachments` with `path` set to the currently selected folder (`NotesListState.selectedPath`), falling back to the vault root when no folder is selected — mirroring how "New note" and "New folder" already target the current folder.

#### Scenario: Uploading a file to the current folder

- **GIVEN** the sidebar has folder `Projects/Alpha` selected
- **WHEN** the user chooses "Upload file" from the FAB menu and picks a file
- **THEN** the app SHALL call `POST /notes/attachments` with `path: "Projects/Alpha"` and the chosen file's bytes and filename

#### Scenario: Cancelling the file picker sends no request

- **WHEN** the user chooses "Upload file" from the FAB menu and dismisses the file picker without choosing a file
- **THEN** the app SHALL send no request

#### Scenario: A successful upload confirms what was stored

- **WHEN** an upload succeeds
- **THEN** the app SHALL show a confirmation naming the uploaded file's stored filename

#### Scenario: A failed upload shows a real error

- **WHEN** `POST /notes/attachments` fails
- **THEN** the app SHALL show the server's error message (falling back to a generic message when none is provided), not a raw or empty error
