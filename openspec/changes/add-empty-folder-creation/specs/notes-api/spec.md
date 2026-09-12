## MODIFIED Requirements

### Requirement: GET /notes/tree returns the folder hierarchy

`GET /notes/tree` SHALL return a JSON object describing the vault's folder structure without paginating individual notes: `{ folders: [{ path, note_count }] }`, one entry per distinct folder that either directly contains at least one note or has been explicitly created as an empty folder (per `notes-storage`), sorted by path. `note_count` SHALL count only notes directly in that folder, not in its subfolders, and SHALL be `0` for a folder with no notes. An intermediate folder that holds no notes and was never explicitly created but has a descendant folder that does (e.g. `Projects` when only `Projects/Alpha` has notes) SHALL NOT get its own entry; clients that want an aggregate count or need to render intermediate tree nodes SHALL derive them from the listed leaf paths. The endpoint SHALL require authentication.

#### Scenario: Tree lists folders with notes

- **GIVEN** notes exist at vault root, `Projects/Alpha`, and `Projects/Beta`
- **WHEN** a client requests `GET /notes/tree`
- **THEN** the response SHALL contain folder entries for `""`, `Projects/Alpha`, and `Projects/Beta` with their respective note counts

#### Scenario: Folder with no notes is not listed

- **GIVEN** an empty directory exists on disk with no note files and no empty-folder marker in it
- **WHEN** a client requests `GET /notes/tree`
- **THEN** that folder SHALL NOT appear in `folders`

#### Scenario: Explicitly created empty folder is listed with a zero count

- **GIVEN** a folder `Ideas` was created via `POST /notes/tree` and has no notes
- **WHEN** a client requests `GET /notes/tree`
- **THEN** the response SHALL contain a `folders` entry `{ "path": "Ideas", "note_count": 0 }`

## ADDED Requirements

### Requirement: POST /notes/tree creates an empty folder

`POST /notes/tree` SHALL accept a JSON body `{ "path": "<folder>" }` where `path` is a non-empty string using `/` as the separator with no leading or trailing slash, create the folder (and any missing intermediate folders along `path`) if it does not already exist, and respond with HTTP 201 and body `{ "path": "<normalized-path>", "note_count": <n> }`. When the folder already exists — whether because it holds notes or was previously created empty — the endpoint SHALL respond with HTTP 200 and the folder's current `note_count` rather than an error. The endpoint SHALL require authentication.

#### Scenario: Creating a new empty folder

- **WHEN** a client posts `{ "path": "Ideas" }` to `POST /notes/tree`
- **THEN** the response SHALL be HTTP 201 with body `{ "path": "Ideas", "note_count": 0 }`
- **AND** a subsequent `GET /notes/tree` SHALL list `Ideas` with `note_count: 0`

#### Scenario: Creating a nested folder creates intermediate folders

- **WHEN** a client posts `{ "path": "Projects/Gamma/Sub" }` to `POST /notes/tree` and no part of that path exists yet
- **THEN** the response SHALL be HTTP 201
- **AND** a subsequent `GET /notes/tree` SHALL list `Projects/Gamma/Sub` (per the existing rule, the intermediate `Projects` and `Projects/Gamma` entries are not listed unless they directly hold a note or were themselves explicitly created)

#### Scenario: Re-creating an existing folder is idempotent

- **GIVEN** folder `Projects/Alpha` already contains two notes
- **WHEN** a client posts `{ "path": "Projects/Alpha" }` to `POST /notes/tree`
- **THEN** the response SHALL be HTTP 200 with body `{ "path": "Projects/Alpha", "note_count": 2 }`, and neither note SHALL be altered

#### Scenario: Empty path is rejected

- **WHEN** a client posts `{ "path": "" }` to `POST /notes/tree`
- **THEN** the response SHALL be HTTP 400, since the vault root always exists and does not need to be created
