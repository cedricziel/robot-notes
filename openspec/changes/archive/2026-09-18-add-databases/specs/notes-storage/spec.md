# Spec Delta

## ADDED Requirements

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
