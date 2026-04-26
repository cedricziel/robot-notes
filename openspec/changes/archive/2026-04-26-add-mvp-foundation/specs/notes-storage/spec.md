## ADDED Requirements

### Requirement: Notes are persisted as markdown files on disk

The server SHALL store each note as a single markdown file at `<data-dir>/content/<id>.md`, where `<data-dir>` is the configured data directory and `<id>` is the note's ULID identifier. The filesystem SHALL be the canonical source of truth for note content, identity, title, and version.

#### Scenario: Creating a note writes a file

- **WHEN** a client successfully creates a note with id `01HXY...ABC`
- **THEN** the file `<data-dir>/content/01HXY...ABC.md` SHALL exist on disk

#### Scenario: Deleting a note removes the file

- **WHEN** a client successfully deletes note `01HXY...ABC`
- **THEN** the file `<data-dir>/content/01HXY...ABC.md` SHALL no longer exist on disk

### Requirement: Note identifiers are ULIDs

The server SHALL generate a Crockford-base32 ULID for every new note. Identifiers SHALL be 26 characters, lexicographically sortable, and the filename SHALL be `<id>.md`.

#### Scenario: Newly created notes receive a ULID

- **WHEN** a client posts to `POST /notes`
- **THEN** the response body SHALL include a 26-character ULID as `id`

#### Scenario: Identifier is sortable by creation time

- **GIVEN** two notes created sequentially
- **WHEN** their identifiers are sorted lexicographically
- **THEN** the earlier-created note's identifier SHALL sort first

### Requirement: Each note carries YAML frontmatter

Every note file SHALL begin with a YAML frontmatter block delimited by `---` on its own lines. The frontmatter SHALL include the keys `id`, `title`, `version`, `created_at`, and `updated_at`. Timestamps SHALL be ISO 8601 in UTC. The server SHALL preserve unknown frontmatter keys on round-trip (read, modify, write) so external tools can extend the schema.

#### Scenario: Newly created note has all required frontmatter keys

- **WHEN** a note is created
- **THEN** the file SHALL begin with a YAML frontmatter block containing `id`, `title`, `version: 1`, `created_at`, and `updated_at`

#### Scenario: Unknown frontmatter keys are preserved across writes

- **GIVEN** a note file whose frontmatter contains an extra key `tags: [planning]`
- **WHEN** the server reads the note, modifies its content, and writes it back
- **THEN** the saved file SHALL still contain `tags: [planning]` in its frontmatter

#### Scenario: Frontmatter parse failure surfaces a clear error

- **GIVEN** a note file with malformed YAML frontmatter
- **WHEN** the server attempts to read the note at startup or on request
- **THEN** the server SHALL log an error naming the file and SHALL exclude it from the index until corrected

### Requirement: Version is a monotonic integer in frontmatter

Every note's frontmatter SHALL contain a `version` field that is a positive integer. New notes SHALL have `version: 1`. On every successful write the server SHALL increment the version by exactly 1.

#### Scenario: Version starts at 1

- **WHEN** a note is created
- **THEN** its `version` SHALL equal 1

#### Scenario: Version increments by 1 on each successful save

- **GIVEN** a note at version 5
- **WHEN** a successful update is applied
- **THEN** the saved file SHALL have `version: 6`

### Requirement: Writes are atomic via tmp + fsync + rename

The server SHALL never write directly to a note's final path. All writes SHALL go through this sequence: create a sibling temporary file, write the full new contents, fsync, then rename over the destination. A reader SHALL never observe a partial or torn file.

#### Scenario: Crash mid-write does not corrupt the canonical file

- **GIVEN** a note file at version 5
- **WHEN** the server is killed after writing the temporary file but before the rename completes
- **THEN** the canonical file SHALL still contain version 5 and SHALL parse cleanly on next startup

### Requirement: Server maintains an in-memory metadata index

The server SHALL hold an in-memory map keyed by note id that exposes at minimum `title`, `version`, `created_at`, and `updated_at`. The index SHALL be the authoritative source for list operations and version checks during the server's lifetime.

#### Scenario: List operation returns metadata from the index

- **WHEN** a client requests `GET /notes`
- **THEN** the server SHALL serve titles and versions from its in-memory index without re-reading every file

#### Scenario: Index is updated atomically on every write

- **WHEN** a note save completes successfully
- **THEN** the in-memory index entry for that note SHALL reflect the new version and `updated_at` before the response is returned to the client

#### Scenario: Index entry is removed on delete

- **WHEN** a note is deleted
- **THEN** the in-memory index SHALL no longer contain an entry for that id before the response is returned

### Requirement: Server rebuilds the metadata index on startup

On every startup the server SHALL scan `<data-dir>/content/*.md`, parse each file's frontmatter, and populate the metadata index. Files that fail to parse SHALL be logged and excluded but SHALL NOT prevent startup.

#### Scenario: All notes are indexed on startup

- **GIVEN** `<data-dir>/content` contains three valid `.md` files
- **WHEN** the server starts
- **THEN** the in-memory index SHALL contain three entries

#### Scenario: A malformed file is logged and skipped

- **GIVEN** `<data-dir>/content` contains two valid notes and one with broken YAML
- **WHEN** the server starts
- **THEN** the server SHALL log a warning naming the malformed file, the index SHALL contain the two valid notes, and startup SHALL succeed

### Requirement: Out-of-band file changes are not supported during a session

The server SHALL document that direct filesystem edits to `<data-dir>/content/*.md` made while the server is running are not picked up until the next restart. The server SHALL NOT watch the filesystem for external changes in v1.

#### Scenario: Manual edit during runtime is invisible until restart

- **GIVEN** the server is running
- **WHEN** an operator edits a note file directly on disk
- **AND** a client requests the note via the API
- **THEN** the server SHALL return the version it has cached in memory, ignoring the external edit

### Requirement: Concurrent writes to the same note are serialized

The server SHALL ensure that for any single note id, writes are processed one at a time in the order they are received. The server SHOULD allow concurrent writes to *different* notes.

#### Scenario: Two simultaneous writes to the same note are linearized

- **GIVEN** a note at version 5
- **WHEN** two PUT requests for the same note arrive concurrently, both with `If-Match: 5`
- **THEN** exactly one SHALL succeed with version 6 and the other SHALL receive HTTP 409
