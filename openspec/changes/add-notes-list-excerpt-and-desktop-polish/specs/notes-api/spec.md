## MODIFIED Requirements

### Requirement: GET /notes returns paginated metadata

`GET /notes` SHALL return a JSON object containing `items` (an array of note metadata) and `next_cursor` (a string or null). Each item SHALL contain `id`, `title`, `path`, `version`, `updated_at`, `created_at`, `excerpt`, and `tags`. `excerpt` SHALL be a bounded, plain-text preview of the note body — not the note's full content. `tags` SHALL be the note's computed tag set (array of strings), the same set used for the `tag` filter. The endpoint SHALL accept `limit` (default 50, max 200), `after`, `sort`, `path` (return only notes whose `path` equals or is nested under the given folder), and `tag` (return only notes carrying the given tag) query parameters. `after` is an opaque cursor derived from the last item of the previous page. `path` and `tag` MAY be combined with either `sort` value and with each other; they narrow the result set before pagination is applied. Item full content SHALL NOT be included.

`sort` SHALL be one of:

- `id` (default) — ascending by `id`, preserved for backward compatibility. The cursor is the last item's plain `id`.
- `updated_desc` — descending by `updated_at`, ties broken by `id` descending, so pagination stays stable while notes are created or edited. The cursor is an opaque string encoding both `updated_at` and `id`.

Any other `sort` value SHALL be rejected with HTTP 400. A cursor that cannot be decoded for the requested `sort` SHALL also be rejected with HTTP 400.

#### Scenario: Default page size is 50

- **GIVEN** the server holds 100 notes
- **WHEN** a client requests `GET /notes` with no query parameters
- **THEN** the response SHALL contain `items` of length 50 and a non-null `next_cursor`

#### Scenario: Cursor pagination returns the next page

- **GIVEN** a previous response returned `next_cursor: "<c>"`
- **WHEN** the client requests `GET /notes?after=<c>`
- **THEN** the response SHALL contain the next page of notes in id-sorted order

#### Scenario: Last page has null next_cursor

- **WHEN** the page returned is the final page
- **THEN** `next_cursor` SHALL be `null`

#### Scenario: Items contain metadata only, no content

- **WHEN** a client requests `GET /notes`
- **THEN** items SHALL NOT contain a `content` field

#### Scenario: Items include a markdown-stripped excerpt

- **GIVEN** a note whose body contains markdown syntax (headings, lists, emphasis, `[[links]]`, inline `#tags`) longer than the excerpt bound
- **WHEN** a client requests `GET /notes`
- **THEN** that item's `excerpt` SHALL be plain text (markdown syntax stripped), truncated to the excerpt bound at a word boundary

#### Scenario: Items include the note's computed tags

- **GIVEN** a note carries tags `urgent` and `travel`
- **WHEN** a client requests `GET /notes`
- **THEN** that item's `tags` SHALL contain `urgent` and `travel`

#### Scenario: sort=updated_desc orders by most recently updated first

- **GIVEN** note A was last updated before note B
- **WHEN** a client requests `GET /notes?sort=updated_desc`
- **THEN** note B SHALL appear before note A in `items`

#### Scenario: sort=updated_desc paginates with an opaque cursor

- **GIVEN** a previous `GET /notes?sort=updated_desc` response returned `next_cursor: "<c>"`
- **WHEN** the client requests `GET /notes?sort=updated_desc&after=<c>`
- **THEN** the response SHALL contain the next page in `updated_at`-descending order

#### Scenario: Unknown sort value is rejected

- **WHEN** a client requests `GET /notes?sort=bogus`
- **THEN** the response SHALL have status 400 and a JSON body `{"error":"bad_request"}`

#### Scenario: Path filter returns only notes under that folder

- **GIVEN** notes exist at `Projects/Alpha/A`, `Projects/Beta/B`, and vault root `C`
- **WHEN** a client requests `GET /notes?path=Projects/Alpha`
- **THEN** `items` SHALL contain only `A`

#### Scenario: Tag filter returns only notes carrying that tag

- **GIVEN** two notes carry tag `urgent` and a third does not
- **WHEN** a client requests `GET /notes?tag=urgent`
- **THEN** `items` SHALL contain exactly the two tagged notes

#### Scenario: Path filter composes with sort=updated_desc

- **GIVEN** two notes under `Projects/Alpha` were updated at different times, and a third, more recently updated note sits at vault root
- **WHEN** a client requests `GET /notes?path=Projects/Alpha&sort=updated_desc`
- **THEN** `items` SHALL contain only the two notes under `Projects/Alpha`, most-recently-updated first
