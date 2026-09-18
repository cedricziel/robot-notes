# Spec Delta

## ADDED Requirements

### Requirement: Property patches are not lock-governed

`PATCH /notes/{id}/properties` and the `update_properties` MCP tool SHALL NOT consult the editor lock, because they cannot modify the note body or title; every other write SHALL remain lock-governed as specified elsewhere in this capability.

#### Scenario: Patch succeeds while another actor holds the lock

- **GIVEN** actor `alice` holds the editor lock on a note
- **WHEN** actor `bob` sends `PATCH /notes/{id}/properties` with a valid change
- **THEN** the response SHALL be HTTP 200 and the lock SHALL remain held by `alice`
