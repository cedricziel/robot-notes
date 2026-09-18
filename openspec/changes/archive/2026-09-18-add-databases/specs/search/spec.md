# Spec Delta

## ADDED Requirements

### Requirement: The index stores frontmatter properties for querying

The search index SHALL store, for every indexed note, its non-reserved frontmatter keys and values in a form that supports equality, substring, numeric, date, and list-membership predicates and ordering without reading note files. The index SHALL be updated in the same transaction as the FTS and link-edge update on every write, removed on delete, and rebuilt from content on the existing schema-mismatch path. The schema version SHALL be bumped so existing indexes rebuild once on upgrade.

#### Scenario: Upgrade rebuilds the index

- **GIVEN** a `search.db` written by the previous schema version
- **WHEN** the server starts
- **THEN** it SHALL rebuild the index from content and property queries SHALL return every existing note's frontmatter values

#### Scenario: Property values are queryable right after a write

- **WHEN** a note is written with `status: Active`
- **THEN** a database query filtering `status eq Active` issued immediately after the write completes SHALL include the note
