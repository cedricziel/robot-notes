# notes-storage Specification

## Purpose

TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.

## Requirements

### Requirement: Notes are persisted as markdown files on disk

The server SHALL store each note as a single markdown file at `<data-dir>/content/<path>/<sanitized-title>.md`, where `<data-dir>` is the configured data directory, `<path>` is the note's folder (empty string SHALL mean the file lives directly under `content/`), and `<sanitized-title>` is the note's title with the characters `\ / : * ? " < > |` stripped or replaced. Every note file SHALL carry the `.md` extension, and folders SHALL never carry it, so a note titled `Foo` and a folder named `Foo` never collide on disk (`Foo.md` vs `Foo/`). The filesystem SHALL be the canonical source of truth for note content, identity, title, path, and version. The note's `id` (see below) SHALL NOT appear in the filename.

#### Scenario: Creating a note writes a file

- **WHEN** a client successfully creates a note with title `Meeting Notes` and path `Projects/Alpha`
- **THEN** the file `<data-dir>/content/Projects/Alpha/Meeting Notes.md` SHALL exist on disk

#### Scenario: Creating a note at vault root

- **WHEN** a client successfully creates a note with title `Inbox` and no path
- **THEN** the file `<data-dir>/content/Inbox.md` SHALL exist on disk

#### Scenario: Deleting a note removes the file

- **GIVEN** a note exists at `<data-dir>/content/Projects/Alpha/Meeting Notes.md`
- **WHEN** a client successfully deletes that note
- **THEN** the file SHALL no longer exist on disk

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

Every note file SHALL begin with a YAML frontmatter block delimited by `---` on its own lines. The frontmatter SHALL include the keys `id`, `title`, `path`, `version`, `created_at`, and `updated_at`. `path` SHALL be a string using `/` as the separator with no leading or trailing slash; an empty string denotes the vault root. Timestamps SHALL be ISO 8601 in UTC. The server SHALL preserve unknown frontmatter keys on round-trip (read, modify, write) so external tools can extend the schema. `title` and each `path` segment SHALL be normalized to Unicode NFC before being persisted, compared, or used to derive a filename, so that titles are stable across filesystems that themselves normalize filenames differently (e.g. APFS's on-disk NFD).

#### Scenario: Title is normalized to NFC before use

- **GIVEN** a client submits a title using an NFD-decomposed accented character (e.g. `e` + combining acute)
- **WHEN** the note is created
- **THEN** the stored frontmatter `title`, the filename, and all title-comparison operations (collision checks, link resolution) SHALL use the NFC-composed form

#### Scenario: Newly created note has all required frontmatter keys

- **WHEN** a note is created
- **THEN** the file SHALL begin with a YAML frontmatter block containing `id`, `title`, `path`, `version: 1`, `created_at`, and `updated_at`

#### Scenario: Root-level note has empty path

- **WHEN** a note is created with no folder specified
- **THEN** the frontmatter `path` SHALL be the empty string

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

On every startup the server SHALL recursively scan `<data-dir>/content/**/*.md`, parse each file's frontmatter, and populate the metadata index using the frontmatter `id` (not the filename) as the key. Files that fail to parse SHALL be logged and excluded but SHALL NOT prevent startup.

#### Scenario: All notes are indexed on startup

- **GIVEN** `<data-dir>/content` contains two notes at the root and one nested at `Projects/Alpha/Meeting Notes.md`
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

The server SHALL ensure that for any single note id, writes are processed one at a time in the order they are received. The server SHOULD allow concurrent writes to _different_ notes.

#### Scenario: Two simultaneous writes to the same note are linearized

- **GIVEN** a note at version 5
- **WHEN** two PUT requests for the same note arrive concurrently, both with `If-Match: 5`
- **THEN** exactly one SHALL succeed with version 6 and the other SHALL receive HTTP 409

### Requirement: Changing title or path moves or renames the file on disk

When a note's `title` changes, the server SHALL rename its file within the same folder. When a note's `path` changes, the server SHALL move its file to the new folder, creating intermediate directories as needed. Both operations SHALL happen as part of the same write that changes `version`, using the same tmp-write-then-rename atomicity as any other update. Directories left empty by a move SHALL NOT be deleted by the server.

#### Scenario: Title change renames the file

- **GIVEN** a note exists at `<data-dir>/content/Draft.md`
- **WHEN** its title is changed to `Final`
- **THEN** the file `<data-dir>/content/Final.md` SHALL exist and `<data-dir>/content/Draft.md` SHALL NOT

#### Scenario: Path change moves the file

- **GIVEN** a note exists at `<data-dir>/content/Inbox.md`
- **WHEN** its path is changed to `Projects/Alpha`
- **THEN** the file `<data-dir>/content/Projects/Alpha/Inbox.md` SHALL exist and `<data-dir>/content/Inbox.md` SHALL NOT

#### Scenario: Move leaves the source folder in place even if now empty

- **GIVEN** `Projects/Alpha` contains exactly one note
- **WHEN** that note is moved out of `Projects/Alpha`
- **THEN** the directory `<data-dir>/content/Projects/Alpha` MAY remain on disk and the server SHALL NOT attempt to remove it

### Requirement: A colliding target path is rejected atomically, without modifying either file

When a title or path change would produce a target file path that already belongs to a different note, the server SHALL refuse the write, leave both notes' files unchanged, and surface a `path_conflict` condition to the caller (see `notes-api`). Path comparison for collision detection SHALL be case-insensitive (matching the behavior of the default-case-insensitive filesystems this app targets, e.g. macOS APFS/HFS+ and Windows), even though the file's actual on-disk name and frontmatter `title` preserve the case as written. The server SHALL make the "check target is free, then create/rename/move" sequence atomic with respect to other writes targeting the same computed path — via a per-target-path lock, an OS-level exclusive-create primitive, or equivalent — so that of two concurrent operations that would resolve to the same target path, exactly one SHALL succeed and the other SHALL observe `path_conflict`; neither SHALL silently overwrite the other's file.

#### Scenario: Renaming into an existing title is rejected

- **GIVEN** notes `A.md` and `B.md` both exist at vault root
- **WHEN** a client attempts to rename `B` to `A`
- **THEN** the write SHALL be rejected and both files SHALL remain unchanged on disk

#### Scenario: Case-only difference is treated as a collision

- **GIVEN** a note titled `Ideas` already exists at vault root
- **WHEN** a client attempts to create or rename a different note to the title `ideas` at vault root
- **THEN** the write SHALL be rejected with `path_conflict`, since the two would collide on a case-insensitive filesystem

#### Scenario: Two concurrent renames to the same target path do not both succeed

- **GIVEN** two different notes, B and C, both currently at vault root
- **WHEN** two concurrent requests attempt to rename B to `Target` and C to `Target` respectively
- **THEN** exactly one SHALL succeed in producing `Target.md`, and the other SHALL receive `path_conflict` with its own file unchanged — neither note's file SHALL be silently overwritten or lost

### Requirement: Legacy flat-layout files are migrated on startup

On startup, before building the metadata index, the server SHALL detect files directly under `<data-dir>/content/` whose name matches `<ulid>.md` and whose frontmatter lacks a `path` key. The server SHALL process these files in ascending id order (which is creation order, since ids are ULIDs) for determinism. For each such file the server SHALL set `path` to the empty string and compute `<sanitized-title>.md` as its target name at vault root; if that name is already taken — by a file already present at vault root (migrated or not) or by a name already claimed earlier in this same migration run — the server SHALL de-duplicate by appending ` (2)`, ` (3)`, etc. before the extension, continuing to increment until it finds a name not claimed by any existing or already-migrated file. The migration SHALL log the number of files migrated and SHALL NOT fail startup if an individual file cannot be migrated (that file SHALL be logged and left in its legacy form).

#### Scenario: De-dup does not overwrite a note whose natural title already uses the suffix form

- **GIVEN** a note already exists at vault root titled `Ideas (2)`, and two legacy files both have `title: "Ideas"`
- **WHEN** the server migrates the two legacy files
- **THEN** neither SHALL be written to `Ideas (2).md`; they SHALL become `Ideas.md` and `Ideas (3).md` (or another name not already claimed)

#### Scenario: Legacy note is renamed to its title

- **GIVEN** `<data-dir>/content/01HXY...ABC.md` exists with frontmatter `title: "Ideas"` and no `path` key
- **WHEN** the server starts
- **THEN** the file SHALL be renamed to `<data-dir>/content/Ideas.md` with frontmatter `path: ""`

#### Scenario: Migration de-duplicates colliding titles

- **GIVEN** two legacy files both have `title: "Ideas"`
- **WHEN** the server migrates them
- **THEN** one SHALL become `Ideas.md` and the other `Ideas (2).md`

#### Scenario: Already-migrated files are left alone

- **GIVEN** a file's frontmatter already contains a `path` key
- **WHEN** the server starts
- **THEN** the migration SHALL NOT rename that file

### Requirement: A note's tags merge frontmatter and inline sources

The server SHALL compute a note's tag set as the union of its frontmatter `tags` array (if present) and any `#tag` tokens found in its content (alphanumeric, `-`, `_`, and `/` for nesting, e.g. `#parent/child`). Tags SHALL be case-insensitive for matching purposes but SHALL be displayed in the case they were first written. The computed tag set SHALL be recalculated on every write and on startup index rebuild; it SHALL NOT be written back into the frontmatter `tags` array.

#### Scenario: Frontmatter and inline tags merge

- **GIVEN** a note's frontmatter contains `tags: [planning]` and its content contains the text `next up: #urgent`
- **WHEN** the note is indexed
- **THEN** the note's computed tag set SHALL contain both `planning` and `urgent`

#### Scenario: Nested tag is recognized

- **GIVEN** a note's content contains `#work/robot-notes`
- **WHEN** the note is indexed
- **THEN** the computed tag set SHALL contain `work/robot-notes`

#### Scenario: Duplicate tag across sources counts once

- **GIVEN** a note's frontmatter contains `tags: [urgent]` and its content also contains `#urgent`
- **WHEN** the note is indexed
- **THEN** the computed tag set SHALL contain `urgent` exactly once

### Requirement: Storage-managed, server-interpreted, and property frontmatter keys are distinct

The frontmatter keys `id`, `title`, `path`, `version`, `created_at`, `updated_at` SHALL be storage-managed: written by the storage layer from the note record on every write. The keys `type`, `tags`, `source`, `properties`, and `views` SHALL be server-interpreted: round-tripped verbatim as extension data exactly as today, excluded from the API-level `properties` object, and neither writable nor removable through the typed property endpoints. Every remaining top-level key SHALL be a property key, exposed through the API as `properties`. When the server rewrites a note's frontmatter it SHALL emit storage-managed keys first in a stable order, then the remaining keys in their existing order with newly added keys appended, so a property write produces a minimal diff on disk. A key whose YAML value is a nested map SHALL be preserved verbatim and exposed as a JSON object, but SHALL be rejected as a value by the typed property endpoints. Strings SHALL be written double-quoted, as today, so no value changes type on round-trip.

#### Scenario: Property write keeps key order

- **GIVEN** a note file whose frontmatter lists `status` before `due`
- **WHEN** the server sets `due` and adds `owner`
- **THEN** the rewritten frontmatter SHALL list `status`, `due`, `owner` in that order after the storage-managed keys

#### Scenario: Server-interpreted keys survive a properties-replacing write

- **GIVEN** a note file whose frontmatter contains `tags: [x]`
- **WHEN** a client sends `PUT /notes/{id}` with `properties: {"status":"Done"}`
- **THEN** the saved file SHALL still contain `tags` with the single item `x` and a `status` key with string value `Done`

#### Scenario: `type: database` is preserved on ordinary writes

- **GIVEN** a database definition note
- **WHEN** a client updates its body through `PUT /notes/{id}` without `properties`
- **THEN** `type`, `source`, `properties`, and `views` SHALL be preserved unchanged in the file
