## ADDED Requirements

### Requirement: GET /notes supports exact-folder metadata browsing

`GET /notes` SHALL accept `include_subfolders=true|false`, defaulting to `true`. With `path` supplied and `include_subfolders=false`, the endpoint SHALL return only notes whose folder path equals `path`. An explicitly empty `path` SHALL select root-level notes in this mode. Omitting `path` SHALL retain the existing all-notes behavior. Unsupported parameter values SHALL return HTTP 400 with the existing bad-request JSON shape.

The exact-folder filter SHALL apply before pagination and SHALL compose with existing tag and sort parameters. Existing metadata fields, cursor behavior, limits, and recursive filtering defaults SHALL remain unchanged. Authorization and vault scoping SHALL apply before results and cursors are produced, without revealing inaccessible note metadata.

#### Scenario: Exact folder excludes descendants

- **GIVEN** notes exist directly in Projects and in Projects/Alpha
- **WHEN** a client requests `GET /notes?path=Projects&include_subfolders=false`
- **THEN** only notes directly in Projects SHALL be returned

#### Scenario: Exact root excludes nested folders

- **WHEN** a client requests `GET /notes?path=&include_subfolders=false`
- **THEN** only root-level notes SHALL be returned

#### Scenario: Existing recursive default remains compatible

- **WHEN** a client requests `GET /notes?path=Projects` without the new parameter
- **THEN** notes in Projects and its descendants SHALL remain eligible

#### Scenario: Filtering precedes pagination

- **GIVEN** a folder contains more than one page of matching notes and its descendants contain other notes
- **WHEN** the client follows cursors with the same exact path, tag, and sort filters
- **THEN** every page SHALL contain only matching direct notes and the final page SHALL have a null cursor

#### Scenario: Invalid boolean is rejected

- **WHEN** a client requests `GET /notes?include_subfolders=maybe`
- **THEN** the server SHALL return HTTP 400 with `error: bad_request`

#### Scenario: Restricted metadata stays hidden

- **WHEN** a client lists an exact folder containing readable and unreadable notes
- **THEN** only authorized metadata SHALL appear in results
