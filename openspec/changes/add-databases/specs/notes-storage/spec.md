# Spec Delta

## ADDED Requirements

### Requirement: Reserved frontmatter keys and property keys are distinct

The frontmatter keys `id`, `title`, `path`, `version`, `created_at`, `updated_at`, `type`, `tags`, `source`, `properties`, and `views` SHALL be reserved for the server. Every other top-level frontmatter key SHALL be a property key, exposed through the API as `properties` and writable through the property endpoints. When the server rewrites a note's frontmatter it SHALL emit reserved keys first in a stable order, then property keys in their existing order, with newly added keys appended, so that a property write produces a minimal diff on disk. A frontmatter key whose YAML value is a nested map SHALL be preserved verbatim and exposed as a JSON object, but SHALL be rejected as a value by the typed property endpoints.

#### Scenario: Property write keeps key order

- **GIVEN** a note file whose frontmatter lists `status` before `due`
- **WHEN** the server sets `due` and adds `owner`
- **THEN** the rewritten frontmatter SHALL list `status`, `due`, `owner` in that order after the reserved keys

#### Scenario: `type: database` is preserved on ordinary writes

- **GIVEN** a database definition note
- **WHEN** a client updates its body through `PUT /notes/{id}` without `properties`
- **THEN** `type`, `source`, `properties`, and `views` SHALL be preserved unchanged in the file
