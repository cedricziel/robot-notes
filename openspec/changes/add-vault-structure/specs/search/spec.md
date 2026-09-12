## MODIFIED Requirements

### Requirement: Server provides full-text search via SQLite FTS5

The server SHALL expose `GET /search?q=<query>` returning notes matching the query. Search SHALL be powered by SQLite FTS5 over a virtual table indexing each note's `id`, `title`, `path`, `content`, and computed tag set. The index SHALL be persisted at `<data-dir>/search.db`. The index SHALL additionally maintain a link-edges table recording each note's outgoing links (`source_id`, `target_title`, `target_id` nullable, `resolved` boolean), used to serve the `links` capability's backlink and outgoing-link queries.

#### Scenario: Endpoint exists and is authenticated

- **WHEN** an authenticated client requests `GET /search?q=meeting`
- **THEN** the request SHALL be matched by a route handler and return HTTP 200 with a JSON body

#### Scenario: Unauthenticated request is rejected

- **WHEN** a client without a valid bearer key requests `GET /search?q=meeting`
- **THEN** the response SHALL be HTTP 401

#### Scenario: Index rows carry path and tags

- **GIVEN** a note exists at path `Projects/Alpha` with tag `urgent`
- **WHEN** the index row for that note is inspected
- **THEN** it SHALL record `path == "Projects/Alpha"` and include `urgent` in its tag set

### Requirement: Index is updated on every successful note write

Every successful create, update, or delete of a note (per `notes-api`) SHALL update the FTS index, the tag set, and the link-edges table transactionally before the API response is returned. Creates and updates SHALL `INSERT OR REPLACE` the row keyed by note id, including its current `path` and computed tags, and SHALL recompute its outgoing link-edge rows; deletes SHALL `DELETE` the row and its outgoing link-edge rows.

#### Scenario: Newly created note is searchable immediately

- **GIVEN** a note is created with content containing the word `aardvark`
- **WHEN** a client searches for `aardvark` immediately after the create response
- **THEN** the new note SHALL appear in the results

#### Scenario: Updated note's old content is no longer matched

- **GIVEN** a note had content `flamingo` and is updated to content `pelican`
- **WHEN** a client searches for `flamingo`
- **THEN** that note SHALL NOT appear in the results
- **AND** searching for `pelican` SHALL return that note

#### Scenario: Deleted note is removed from the index

- **GIVEN** a note containing `seal` has been deleted
- **WHEN** a client searches for `seal`
- **THEN** the deleted note SHALL NOT appear in the results

#### Scenario: Moving a note updates its indexed path

- **GIVEN** a note is indexed with path `""`
- **WHEN** the note is moved to path `Projects/Alpha`
- **THEN** the index row for that note SHALL reflect `path == "Projects/Alpha"`

#### Scenario: Editing links updates the link-edges table

- **GIVEN** a note's content is updated to add `[[Other Note]]`
- **WHEN** the write completes
- **THEN** the link-edges table SHALL contain a row with that note as source and `Other Note` as target title

### Requirement: Server rebuilds the index on startup if missing or corrupt

On startup the server SHALL check whether `<data-dir>/search.db` exists and passes `PRAGMA integrity_check`. If the file is missing OR the integrity check fails OR the schema does not match the expected FTS5-plus-tags-plus-link-edges schema, the server SHALL delete the file (if present) and rebuild the index by recursively scanning `<data-dir>/content/**/*.md`, repopulating path, tags, and link edges for every note. Rebuild SHALL log the number of notes indexed and SHALL not block startup beyond completing the rebuild.

#### Scenario: Missing index is rebuilt

- **GIVEN** `<data-dir>/search.db` does not exist
- **WHEN** the server starts with three notes in `content/`
- **THEN** the server SHALL create `search.db` with three rows, their paths and tags populated, and log a rebuild message

#### Scenario: Corrupt index is rebuilt

- **GIVEN** `<data-dir>/search.db` exists but `PRAGMA integrity_check` fails
- **WHEN** the server starts
- **THEN** the server SHALL delete the corrupt file and rebuild the index from `content/`

#### Scenario: Healthy index is reused

- **GIVEN** `<data-dir>/search.db` exists, passes integrity check, and matches schema
- **WHEN** the server starts
- **THEN** the server SHALL NOT rebuild and SHALL reuse the existing index

#### Scenario: Old schema without path/tags/link-edges triggers a rebuild

- **GIVEN** `<data-dir>/search.db` exists from before this change and lacks the tags/link-edges tables
- **WHEN** the server starts
- **THEN** the server SHALL treat the schema as not matching, delete the file, and rebuild

## ADDED Requirements

### Requirement: Search supports filtering by path and tag

`GET /search` SHALL accept optional `path` (restrict results to notes whose `path` equals or is nested under the given folder) and `tag` (restrict results to notes carrying the given tag) query parameters, applied in addition to the `q` full-text match.

#### Scenario: Path filter narrows search results

- **GIVEN** notes matching `q=budget` exist both under `Projects/Alpha` and at vault root
- **WHEN** a client requests `GET /search?q=budget&path=Projects/Alpha`
- **THEN** `items` SHALL contain only the match under `Projects/Alpha`

#### Scenario: Tag filter narrows search results

- **GIVEN** two notes match `q=budget`, only one of which carries tag `finance`
- **WHEN** a client requests `GET /search?q=budget&tag=finance`
- **THEN** `items` SHALL contain only the tagged match
