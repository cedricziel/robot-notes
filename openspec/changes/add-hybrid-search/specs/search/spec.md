## MODIFIED Requirements

### Requirement: Search returns ranked results with snippets

`GET /search` SHALL return a JSON object with `items`, where each item contains `id`, `title`, `snippet`, `rank`, and `updated_at` (the note's last-updated timestamp, ISO 8601 UTC). When an embedding provider is configured and reachable, results SHALL be ranked by Reciprocal Rank Fusion (RRF) combining the BM25 rank order and the vector KNN rank order across the same candidate notes; `rank` SHALL reflect this fused order. When no embedding provider is configured, or the configured provider is unreachable, results SHALL be sorted by BM25 relevance alone (lowest BM25 rank first), unchanged from prior behavior. The snippet SHALL be a substring of the matching content with HTML-safe markers (`<mark>` and `</mark>`) wrapping matched terms.

#### Scenario: Matches are returned in rank order

- **GIVEN** the index contains three notes whose content matches the query with descending relevance
- **WHEN** a client searches for the matching term
- **THEN** items SHALL be ordered most-relevant first

#### Scenario: Snippets highlight matches

- **GIVEN** a note contains the word `architecture` in its content
- **WHEN** a client searches for `architecture`
- **THEN** the snippet for that result SHALL contain `<mark>architecture</mark>` (or a token-matching variant)

#### Scenario: Results carry the note's updated time

- **GIVEN** a note was last updated at a known instant
- **WHEN** a client searches for a term matching that note
- **THEN** the matching item's `updated_at` SHALL equal that instant, formatted as ISO 8601 UTC

#### Scenario: Empty query returns 400

- **WHEN** a client requests `GET /search?q=`
- **THEN** the response SHALL be HTTP 400 with body `{"error":"empty_query"}`

#### Scenario: Missing query parameter returns 400

- **WHEN** a client requests `GET /search` (no `q`)
- **THEN** the response SHALL be HTTP 400

#### Scenario: Semantically related note is found without keyword overlap

- **GIVEN** an embedding provider is configured and reachable
- **AND** a note discusses "switching to OAuth for third-party login" without containing the word "auth"
- **WHEN** a client searches for `auth`
- **THEN** that note SHALL appear in `items` due to vector similarity, even though no keyword matches

#### Scenario: Ranking falls back to BM25-only order when no provider is configured

- **GIVEN** no embedding provider is configured
- **WHEN** a client searches for a term matching multiple notes
- **THEN** `items` SHALL be ordered by BM25 rank alone, identical to pre-hybrid-search behavior

### Requirement: Index is updated on every successful note write

Every successful create, update, or delete of a note (per `notes-api`) SHALL update the FTS index, the tag set, and the link-edges table transactionally before the API response is returned. Creates and updates SHALL `INSERT OR REPLACE` the row keyed by note id, including its current `path` and computed tags, and SHALL recompute its outgoing link-edge rows; deletes SHALL `DELETE` the row and its outgoing link-edge rows. When an embedding provider is configured, creates and updates SHALL additionally (re)compute and store that note's embedding; deletes SHALL remove its stored embedding. Embedding computation SHALL NOT fail the write response: the embedding is computed and awaited before the response, and a provider failure SHALL degrade to no embedding while the write still succeeds and the note remains findable via BM25.

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

#### Scenario: Note embedding is computed on create when a provider is configured

- **GIVEN** an embedding provider is configured and reachable
- **WHEN** a note is created
- **THEN** the vector table SHALL contain an embedding row for that note's id after the create response is returned

#### Scenario: Write succeeds when the embedding provider is unreachable

- **GIVEN** an embedding provider is configured but unreachable
- **WHEN** a note is created or updated
- **THEN** the write SHALL still return success
- **AND** the note SHALL be findable via a BM25-matching query

### Requirement: Server rebuilds the index on startup if missing or corrupt

On startup the server SHALL check whether `<data-dir>/search.db` exists and passes `PRAGMA integrity_check`. If the file is missing OR the integrity check fails OR the schema does not match the expected FTS5-plus-tags-plus-link-edges-plus-vector schema, the server SHALL delete the file (if present) and rebuild the index by recursively scanning `<data-dir>/content/**/*.md`, repopulating path, tags, and link edges for every note. Rebuild SHALL log the number of notes indexed and SHALL not block startup beyond completing the rebuild. If an embedding provider is configured, rebuild SHALL also recompute embeddings for every note, following the same non-blocking backfill behavior as the embedding backfill requirement below.

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

#### Scenario: Rebuild recomputes embeddings when a provider is configured

- **GIVEN** an embedding provider is configured and reachable
- **AND** `<data-dir>/search.db` is missing
- **WHEN** the server starts with notes in `content/`
- **THEN** the rebuilt index SHALL contain an embedding row for each note once the background backfill completes; startup SHALL NOT block on it

## ADDED Requirements

### Requirement: Search index stores per-note vector embeddings

`search.db` SHALL maintain a vector table storing at most one embedding per note, keyed by note id, using a loadable SQLite vector extension. The embedding dimension SHALL match the configured embedding provider's output dimension. The vector table SHALL support a K-nearest-neighbors query given a query embedding.

#### Scenario: Vector table dimension matches the provider

- **GIVEN** an embedding provider configured with a 768-dimension output
- **WHEN** the vector table is created
- **THEN** its embedding column SHALL be declared with 768 dimensions

#### Scenario: KNN query returns nearest notes

- **GIVEN** the vector table contains embeddings for five notes
- **WHEN** a KNN query is run with a query embedding and `k=3`
- **THEN** it SHALL return exactly 3 note ids ordered by ascending distance

### Requirement: Embedding provider is configured via CLI flags or environment variables

The server SHALL support configuring an embedding provider via `--embedding-provider` / `ROBOT_NOTES_EMBEDDING_PROVIDER` (supported value: `ollama`), following the same CLI-flag-or-`ROBOT_NOTES_*`-env-var pattern as the server's other optional settings. The `ollama` adapter SHALL be further configured by `--ollama-base-url` / `ROBOT_NOTES_OLLAMA_BASE_URL` (defaulting to a well-known local address) and `--ollama-embedding-model` / `ROBOT_NOTES_OLLAMA_MODEL` (defaulting to `nomic-embed-text`). When no embedding provider is configured, no embedding provider SHALL be active and semantic ranking SHALL be disabled.

#### Scenario: Ollama provider is enabled via configuration

- **GIVEN** `ROBOT_NOTES_EMBEDDING_PROVIDER=ollama` and `ROBOT_NOTES_OLLAMA_BASE_URL` are set at startup
- **WHEN** the server starts
- **THEN** the Ollama embedding adapter SHALL be active and used for subsequent embedding computation and query-time embedding generation

#### Scenario: No provider configured means no embeddings

- **GIVEN** neither `--embedding-provider` nor `ROBOT_NOTES_EMBEDDING_PROVIDER` is set
- **WHEN** the server starts
- **THEN** no embedding provider SHALL be active and the vector table SHALL remain empty

### Requirement: Search remains available when the embedding provider is unset or unreachable

Search SHALL never fail or return an error solely because semantic ranking is unavailable. When no embedding provider is configured, or a configured provider does not respond to a health/embedding request, `GET /search` and the `search_notes` MCP tool SHALL serve BM25-only results as if hybrid ranking were disabled, without returning an error to the caller.

#### Scenario: Search succeeds when provider is unreachable at query time

- **GIVEN** an embedding provider is configured but not responding
- **WHEN** a client issues `GET /search?q=meeting`
- **THEN** the response SHALL be HTTP 200 with BM25-ranked results
- **AND** the response SHALL NOT include an error indicating the provider is down

### Requirement: Server backfills embeddings for notes that lack one

When an embedding provider is configured and reachable, the server SHALL identify notes whose vector table row is missing (new provider configuration, or notes written before a provider was configured) and compute their embeddings without blocking server startup or any request.

#### Scenario: Backfill runs after enabling a provider for the first time

- **GIVEN** 100 existing notes with no embeddings and no embedding provider previously configured
- **WHEN** the server starts with `ROBOT_NOTES_EMBEDDING_PROVIDER=ollama` newly set
- **THEN** the server SHALL begin computing embeddings for those 100 notes in the background
- **AND** the server SHALL become ready to serve requests before backfill completes

#### Scenario: Notes remain searchable via BM25 during backfill

- **GIVEN** backfill is in progress for a note that has no embedding yet
- **WHEN** a client searches for a term matching that note's content
- **THEN** the note SHALL still appear in results via BM25 matching
