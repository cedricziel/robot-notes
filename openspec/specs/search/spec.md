# search Specification

## Purpose
TBD - created by archiving change add-mvp-foundation. Update Purpose after archive.
## Requirements
### Requirement: Server provides full-text search via SQLite FTS5

The server SHALL expose `GET /search?q=<query>` returning notes matching the query. Search SHALL be powered by SQLite FTS5 over a virtual table indexing each note's `id`, `title`, and `content`. The index SHALL be persisted at `<data-dir>/search.db`.

#### Scenario: Endpoint exists and is authenticated

- **WHEN** an authenticated client requests `GET /search?q=meeting`
- **THEN** the request SHALL be matched by a route handler and return HTTP 200 with a JSON body

#### Scenario: Unauthenticated request is rejected

- **WHEN** a client without a valid bearer key requests `GET /search?q=meeting`
- **THEN** the response SHALL be HTTP 401

### Requirement: Search returns ranked results with snippets

`GET /search` SHALL return a JSON object with `items`, where each item contains `id`, `title`, `snippet`, and `rank`. Results SHALL be sorted by relevance (lowest BM25 rank first). The snippet SHALL be a substring of the matching content with HTML-safe markers (`<mark>` and `</mark>`) wrapping matched terms.

#### Scenario: Matches are returned in rank order

- **GIVEN** the index contains three notes whose content matches the query with descending relevance
- **WHEN** a client searches for the matching term
- **THEN** items SHALL be ordered most-relevant first

#### Scenario: Snippets highlight matches

- **GIVEN** a note contains the word `architecture` in its content
- **WHEN** a client searches for `architecture`
- **THEN** the snippet for that result SHALL contain `<mark>architecture</mark>` (or a token-matching variant)

#### Scenario: Empty query returns 400

- **WHEN** a client requests `GET /search?q=`
- **THEN** the response SHALL be HTTP 400 with body `{"error":"empty_query"}`

#### Scenario: Missing query parameter returns 400

- **WHEN** a client requests `GET /search` (no `q`)
- **THEN** the response SHALL be HTTP 400

### Requirement: Search supports a maximum result limit

`GET /search` SHALL accept an optional `limit` query parameter (default 20, max 100). Results in excess of the limit SHALL be omitted from the response.

#### Scenario: Default limit is 20

- **GIVEN** 50 notes match the query
- **WHEN** a client requests `GET /search?q=...`
- **THEN** items SHALL contain at most 20 entries

#### Scenario: Custom limit is honored

- **WHEN** a client requests `GET /search?q=...&limit=5`
- **THEN** items SHALL contain at most 5 entries

#### Scenario: Limit above maximum is clamped

- **WHEN** a client requests `GET /search?q=...&limit=500`
- **THEN** items SHALL contain at most 100 entries

### Requirement: Index uses Porter stemming and unicode tokenization

The FTS5 virtual table SHALL be configured with `tokenize='porter unicode61'`. Searches SHALL match stemmed forms (e.g. `running` matches `run`) and SHALL be case- and diacritic-insensitive.

#### Scenario: Stemmed match

- **GIVEN** a note containing the word `running`
- **WHEN** a client searches for `run`
- **THEN** the note SHALL appear in results

#### Scenario: Case-insensitive match

- **GIVEN** a note containing `Architecture`
- **WHEN** a client searches for `architecture`
- **THEN** the note SHALL appear in results

### Requirement: Index is updated on every successful note write

Every successful create, update, or delete of a note (per `notes-api`) SHALL update the FTS index transactionally before the API response is returned. Creates and updates SHALL `INSERT OR REPLACE` the row keyed by note id; deletes SHALL `DELETE` the row.

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

### Requirement: Index is the derived state, not the source of truth

The index at `<data-dir>/search.db` SHALL be treated as a rebuildable cache. The server SHALL be able to delete and reconstruct it without losing any note data. The markdown files in `<data-dir>/content/` SHALL remain the canonical store of content.

#### Scenario: Deleted index can be reconstructed

- **GIVEN** the server is shut down and `<data-dir>/search.db` is removed
- **WHEN** the server starts
- **THEN** the server SHALL rebuild the index from `<data-dir>/content/*.md` and search SHALL function normally

### Requirement: Server rebuilds the index on startup if missing or corrupt

On startup the server SHALL check whether `<data-dir>/search.db` exists and passes `PRAGMA integrity_check`. If the file is missing OR the integrity check fails OR the schema does not match the expected FTS5 schema, the server SHALL delete the file (if present) and rebuild the index by scanning `<data-dir>/content/*.md`. Rebuild SHALL log the number of notes indexed and SHALL not block startup beyond completing the rebuild.

#### Scenario: Missing index is rebuilt

- **GIVEN** `<data-dir>/search.db` does not exist
- **WHEN** the server starts with three notes in `content/`
- **THEN** the server SHALL create `search.db` with three rows and log a rebuild message

#### Scenario: Corrupt index is rebuilt

- **GIVEN** `<data-dir>/search.db` exists but `PRAGMA integrity_check` fails
- **WHEN** the server starts
- **THEN** the server SHALL delete the corrupt file and rebuild the index from `content/`

#### Scenario: Healthy index is reused

- **GIVEN** `<data-dir>/search.db` exists, passes integrity check, and matches schema
- **WHEN** the server starts
- **THEN** the server SHALL NOT rebuild and SHALL reuse the existing index

### Requirement: Search query syntax uses FTS5 MATCH syntax

The `q` parameter SHALL be passed to FTS5 as a `MATCH` query. Clients MAY use FTS5 features such as prefix matching (`foo*`), AND/OR/NOT, and quoted phrases. Query strings that produce a syntax error in FTS5 SHALL result in HTTP 400 with body `{"error":"invalid_query"}`.

#### Scenario: Phrase query

- **GIVEN** a note contains the phrase `release notes`
- **WHEN** a client searches for `"release notes"`
- **THEN** that note SHALL appear in results

#### Scenario: Prefix query

- **GIVEN** a note contains the word `architecture`
- **WHEN** a client searches for `archi*`
- **THEN** that note SHALL appear in results

#### Scenario: Invalid query is rejected

- **WHEN** a client searches with `q="unbalanced`
- **THEN** the response SHALL be HTTP 400 with body `{"error":"invalid_query"}`

