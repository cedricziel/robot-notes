## MODIFIED Requirements

### Requirement: Server emits `changed` events on note writes

On every successful create, update, move, or delete of a note (per `notes-api`), the server SHALL emit a `changed` event to all current subscribers of that note (including wildcard subscribers). The event SHALL have shape `{"type":"changed","note_id":"<id>","version":<int>|null,"by":"<actor>","action":"created|updated|moved|deleted"}`. The event SHALL NOT include note content or path; clients SHALL fetch via HTTP to retrieve the new state.

#### Scenario: Update emits changed event with new version

- **GIVEN** subscribers exist for note X
- **WHEN** a successful PUT brings note X to version 6 by actor `alice`
- **THEN** subscribers SHALL receive `{"type":"changed","note_id":"X","version":6,"by":"alice","action":"updated"}`

#### Scenario: Delete emits changed event with null version

- **WHEN** note X is successfully deleted by `alice`
- **THEN** subscribers SHALL receive `{"type":"changed","note_id":"X","version":null,"by":"alice","action":"deleted"}`

#### Scenario: Created note emits version 1

- **WHEN** a new note is successfully created by `alice`
- **THEN** subscribers (including wildcard) SHALL receive a `changed` event with `version: 1` and `action: "created"`

#### Scenario: Moving a note emits a moved action

- **GIVEN** subscribers exist for note X
- **WHEN** note X is moved to a new folder by actor `alice`, bringing it to version 4
- **THEN** subscribers SHALL receive `{"type":"changed","note_id":"X","version":4,"by":"alice","action":"moved"}`

#### Scenario: Rename-propagation rewrite emits an updated action for the rewritten note

- **GIVEN** note B links to note A and subscribers exist for note B
- **WHEN** note A is renamed, causing the server to rewrite note B's content (per `links`)
- **THEN** subscribers of note B SHALL receive a `changed` event for note B with `action: "updated"`
