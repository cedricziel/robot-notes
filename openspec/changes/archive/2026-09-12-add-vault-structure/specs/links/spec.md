## Purpose

Lets notes reference each other with Obsidian-style `[[wikilinks]]` and lets users discover those relationships through backlinks, so the note collection becomes a connected graph instead of isolated documents.

## ADDED Requirements

### Requirement: Notes support inline `[[Title]]` and `[[Title|Alias]]` links

Note content MAY contain inline links of the form `[[Title]]` or `[[Title|Alias]]`, where `Title` is another note's title and `Alias` is optional display text. The server SHALL parse these links from a note's content on every write and on startup index rebuild. Link parsing SHALL NOT alter the stored markdown; the raw `[[...]]` text SHALL remain in the file exactly as written.

#### Scenario: Simple link is parsed

- **GIVEN** a note's content contains `See [[Project Alpha]] for details`
- **WHEN** the note is saved
- **THEN** the server SHALL record an outgoing link from this note with target title `Project Alpha`

#### Scenario: Aliased link is parsed

- **GIVEN** a note's content contains `See [[Project Alpha|the plan]]`
- **WHEN** the note is saved
- **THEN** the server SHALL record an outgoing link with target title `Project Alpha` and alias `the plan`

#### Scenario: Heading anchors are not parsed as separate targets

- **GIVEN** a note's content contains `[[Project Alpha#Milestones]]`
- **WHEN** the note is saved
- **THEN** the server SHALL treat the target title as the full bracketed text `Project Alpha#Milestones` (heading-anchor resolution is not supported in this version)

#### Scenario: A title containing a literal pipe or closing brackets cannot be linked unambiguously

- **GIVEN** a note is titled `Before | After`
- **WHEN** another note contains `[[Before | After]]`
- **THEN** the server MAY parse `After` as an alias of a link to `Before` rather than resolving the full title (this is a documented limitation: titles containing `|` or `]]` are not reliably linkable in v1)

### Requirement: Server maintains a title-to-id resolution index

The server SHALL maintain an in-memory index mapping each note's title to its id, rebuilt on startup alongside the metadata index and updated on every create, update (title change), and delete. Outgoing links SHALL be resolved against this index to determine their target note id.

#### Scenario: Link resolves to an existing note

- **GIVEN** a note titled `Project Alpha` exists with id `01J...A`
- **WHEN** another note is saved containing `[[Project Alpha]]`
- **THEN** the server SHALL resolve that link to target id `01J...A`

#### Scenario: Duplicate titles resolve deterministically with a warning

- **GIVEN** two notes both titled `Project Alpha` exist with different ids
- **WHEN** a link `[[Project Alpha]]` is resolved
- **THEN** the server SHALL resolve it to whichever of the two ids sorts first, and SHALL log an ambiguous-title warning naming both ids

### Requirement: Links to a not-yet-existing title are valid phantom links

A link whose target title does not currently match any note SHALL be stored as unresolved ("phantom") rather than rejected. When a note is later created with that exact title, previously phantom links to it SHALL become resolved without requiring the linking notes to be re-saved.

#### Scenario: Phantom link is accepted

- **WHEN** a note is saved containing `[[Not Yet Written]]` and no note has that title
- **THEN** the save SHALL succeed and the link SHALL be recorded with `resolved: false`

#### Scenario: Phantom link resolves once the target is created

- **GIVEN** a note contains the phantom link `[[Not Yet Written]]`
- **WHEN** a new note titled `Not Yet Written` is created
- **THEN** a subsequent query of the linking note's outgoing links SHALL show that link as `resolved: true` with the new note's id

### Requirement: Renaming a note propagates to notes that link to it

When a note's title changes, the server SHALL find every other note with a _parsed_ outgoing link (per the link-parsing requirement above, not a raw text search) whose target title equals the old title, and rewrite each such `[[OldTitle]]` or `[[OldTitle|...]]` occurrence to use the new title, preserving any alias text. This SHALL NOT rewrite incidental occurrences of the old title text that are not inside a parsed link. Each rewritten note SHALL be saved as a normal write (version incremented, `changed` event broadcast, `by` set to the actor who performed the rename). If a note that needs rewriting is currently locked by an actor other than the one performing the rename, the server SHALL skip rewriting that note and SHALL log a warning naming the note id and lock holder.

#### Scenario: Rename rewrites a referencing note

- **GIVEN** note B contains `[[Old Name]]` linking to note A
- **WHEN** note A's title changes from `Old Name` to `New Name`
- **THEN** note B's content SHALL be rewritten to contain `[[New Name]]` and note B's version SHALL increment

#### Scenario: Aliased link preserves its alias on rename

- **GIVEN** note B contains `[[Old Name|the plan]]`
- **WHEN** note A's title changes from `Old Name` to `New Name`
- **THEN** note B's content SHALL contain `[[New Name|the plan]]`

#### Scenario: Locked referencing note is skipped

- **GIVEN** note B contains `[[Old Name]]` and is currently locked by actor `bob`
- **WHEN** actor `alice` renames note A from `Old Name` to `New Name`
- **THEN** note B SHALL NOT be rewritten and the server SHALL log a warning naming note B and holder `bob`

#### Scenario: Propagated rewrite is attributed to the renaming actor

- **GIVEN** note B links to note A
- **WHEN** actor `alice` renames note A, causing note B to be rewritten
- **THEN** the `changed` event broadcast for note B's rewrite SHALL have `by: "alice"`

#### Scenario: Incidental plain-text mention of the old title is not rewritten

- **GIVEN** note B contains the plain sentence `Old Name was a great project` with no `[[...]]` around it
- **WHEN** note A's title changes from `Old Name` to `New Name`
- **THEN** note B's content SHALL remain unchanged, since the mention was never a parsed link

### Requirement: Server exposes backlinks and outgoing links per note

`GET /notes/{id}/backlinks` SHALL return `{ items: [{ id, title, snippet }] }` listing every note whose content contains a link resolving to the given note, most-recently-updated first. `GET /notes/{id}/links` SHALL return `{ items: [{ title, resolved, id? }] }` listing the note's outgoing links, where `id` is present only when `resolved` is `true`. Both endpoints SHALL require authentication and SHALL return 404 for an unknown note id.

#### Scenario: Backlinks lists referencing notes

- **GIVEN** notes B and C both link to note A
- **WHEN** a client requests `GET /notes/A/backlinks`
- **THEN** the response SHALL be 200 with `items` containing both B and C

#### Scenario: Outgoing links show resolution state

- **GIVEN** note A contains `[[Existing Note]]` and `[[Missing Note]]`, only the first of which exists
- **WHEN** a client requests `GET /notes/A/links`
- **THEN** the response SHALL contain one item with `resolved: true` and an `id`, and one item with `resolved: false` and no `id`

#### Scenario: Unknown note id returns 404

- **WHEN** a client requests `GET /notes/{id}/backlinks` for an id with no corresponding note
- **THEN** the response SHALL be HTTP 404
