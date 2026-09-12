## MODIFIED Requirements

### Requirement: Server rebuilds the metadata index on startup

On every startup the server SHALL recursively scan `<data-dir>/content/**/*.md`, parse each file's frontmatter, and populate the metadata index using the frontmatter `id` (not the filename) as the key. Files that fail to parse SHALL be logged and excluded but SHALL NOT prevent startup. The server SHALL also scan for empty-folder marker files (see "Empty folders are persisted via a marker file") and register each marked folder so it is known to the folder-tree derivation even when it holds no notes.

#### Scenario: All notes are indexed on startup

- **GIVEN** `<data-dir>/content` contains two notes at the root and one nested at `Projects/Alpha/Meeting Notes.md`
- **WHEN** the server starts
- **THEN** the in-memory index SHALL contain three entries

#### Scenario: A malformed file is logged and skipped

- **GIVEN** `<data-dir>/content` contains two valid notes and one with broken YAML
- **WHEN** the server starts
- **THEN** the server SHALL log a warning naming the malformed file, the index SHALL contain the two valid notes, and startup SHALL succeed

#### Scenario: A marker-only folder is registered without any notes

- **GIVEN** `<data-dir>/content/Ideas/` exists on disk containing only an empty-folder marker file and no `.md` files
- **WHEN** the server starts
- **THEN** the folder-tree derivation SHALL know about `Ideas` with a note count of zero

## ADDED Requirements

### Requirement: Empty folders are persisted via a marker file

A folder created with no notes in it SHALL be made durable by writing a marker file into it that is not a note: it SHALL NOT carry the `.md` extension, SHALL be excluded from every note listing, search, link-parsing, and tag-computation operation, and SHALL NOT itself be addressable by an `id`. The marker file's sole purpose is to make the folder's existence survive a server restart and be discoverable by the startup scan. Creating a note inside a marked folder SHALL NOT require removing the marker, and the marker MAY remain indefinitely once notes exist alongside it.

#### Scenario: Marker file does not appear as a note

- **GIVEN** folder `Ideas` was created empty and contains only its marker file
- **WHEN** a client requests `GET /notes` or `GET /search?q=...`
- **THEN** the marker file SHALL NOT appear in either response

#### Scenario: Marker survives a note being added to the folder

- **GIVEN** folder `Ideas` contains only its marker file
- **WHEN** a note is created with path `Ideas`
- **THEN** both the marker file and the new note file SHALL exist in `<data-dir>/content/Ideas/`

#### Scenario: Marker survives the folder becoming empty again

- **GIVEN** folder `Ideas` contains its marker file and one note
- **WHEN** that note is deleted or moved out of `Ideas`
- **THEN** the marker file SHALL remain, and `Ideas` SHALL still be known to the folder-tree derivation with a note count of zero

### Requirement: Creating an already-existing folder is idempotent

Creating a folder at a path that already has notes, an existing marker file, or resolves (case-insensitively, NFC-normalized, per the existing path-collision rules) to an already-known folder SHALL succeed without error and SHALL NOT duplicate the marker file or alter any existing note.

#### Scenario: Re-creating an empty folder is a no-op

- **GIVEN** folder `Ideas` already exists with only its marker file
- **WHEN** a folder is created again at path `Ideas`
- **THEN** the operation SHALL succeed and the folder's state SHALL be unchanged

#### Scenario: Creating a folder that already has notes is a no-op

- **GIVEN** folder `Projects/Alpha` already contains two notes
- **WHEN** a folder is created at path `Projects/Alpha`
- **THEN** the operation SHALL succeed without adding a marker file or altering either note

#### Scenario: Case-only path is treated as the same folder

- **GIVEN** folder `Ideas` already exists
- **WHEN** a folder is created at path `ideas`
- **THEN** the operation SHALL succeed and SHALL resolve to the existing `Ideas` folder rather than creating a second one
