# Spec Delta

## ADDED Requirements

### Requirement: Relation property values are outgoing links

Wikilinks appearing as values of a frontmatter key declared as a `relation` property by any database covering the note SHALL be parsed as outgoing links exactly as inline `[[Title]]` links in the body are: they SHALL be resolved against the title index, appear in `GET /notes/{id}/links`, produce backlinks on the target, and be rewritten by rename propagation when the target note is renamed. Wikilink-shaped strings in frontmatter keys that are not declared as relations SHALL NOT be parsed as links.

#### Scenario: Relation produces a backlink

- **GIVEN** a database declares `owner` as a `relation` and row R has `owner: ["[[Alice]]"]`
- **WHEN** a client requests backlinks of the note titled `Alice`
- **THEN** R SHALL be listed

#### Scenario: Rename rewrites the relation value

- **GIVEN** row R has `owner: ["[[Alice]]"]`
- **WHEN** the note `Alice` is renamed to `Alice Smith`
- **THEN** R's frontmatter SHALL contain `owner: ["[[Alice Smith]]"]` and R's version SHALL increment

#### Scenario: Undeclared wikilink in frontmatter is not a link

- **GIVEN** a note in no database has `related: "[[Bob]]"` in its frontmatter
- **WHEN** a client requests its outgoing links
- **THEN** `Bob` SHALL NOT be listed
