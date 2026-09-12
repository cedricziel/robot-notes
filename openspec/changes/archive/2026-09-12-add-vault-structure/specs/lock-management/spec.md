## ADDED Requirements

### Requirement: Moving or renaming a note is a lock-governed write

A note's `path` or `title` change (per `notes-storage`, `notes-api`) SHALL be subject to the same lock rules as a content update: if another actor holds an active lock on the note, the move/rename SHALL be rejected with HTTP 423 (or the equivalent `locked` tool error over MCP) and neither the file nor the frontmatter SHALL change.

#### Scenario: Move blocked by another actor's lock

- **GIVEN** note X is locked by `bob`
- **WHEN** a request with `X-Actor: alice` sends `PUT /notes/X` with a `path` change and a matching `If-Match`
- **THEN** the response SHALL be 423 and the note SHALL remain at its original path

#### Scenario: Lock holder can move their own note

- **GIVEN** note X is locked by `alice`
- **WHEN** a request with `X-Actor: alice` sends `PUT /notes/X` with a `path` change and a matching `If-Match`
- **THEN** the response SHALL be 200 and the note SHALL be moved

### Requirement: Rename-propagation writes respect locks on the notes being rewritten

When renaming a note causes the server to rewrite `[[link]]` text in other notes (per `links`), each rewrite SHALL be treated as a write to that other note and SHALL be skipped, not forced, if that note is currently locked by an actor other than the one performing the rename. This applies independently of whether the renaming actor holds a lock on the note being renamed itself.

#### Scenario: Rewrite skips a note locked by someone else

- **GIVEN** note B links to note A and note B is locked by `bob`
- **WHEN** actor `alice` renames note A
- **THEN** note B's content SHALL NOT be rewritten while `bob`'s lock is active
