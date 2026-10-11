## ADDED Requirements

### Requirement: Task recall scope narrows configured roots

When a task folder is configured, automatic recall SHALL search only the intersection of that folder and configured recall roots within the selected vault. Folder names SHALL NOT act as authorization credentials. Without a task folder, configured recall roots SHALL remain unchanged.

#### Scenario: Task folder contains an identity root

- **GIVEN** recall is scoped to `people/alice`
- **WHEN** the task folder is `people`
- **THEN** recall searches `people/alice` and does not search another person's folder

#### Scenario: Disjoint task folder

- **GIVEN** recall is scoped to `people/alice`
- **WHEN** the task folder is `people/bob`
- **THEN** recall returns no context without widening the configured scope

### Requirement: Optional evidence context obeys a byte budget

When a recall byte budget is configured, injected context SHALL NOT exceed that UTF-8 byte count, including headers and source metadata. Each included source SHALL retain its note ID and update timestamp when available. Truncation SHALL preserve valid UTF-8. Unconfigured recall SHALL preserve the existing format.

#### Scenario: Multibyte evidence exceeds the budget

- **WHEN** evidence containing multibyte characters exceeds the configured budget
- **THEN** the injected text remains valid UTF-8 and its encoded byte count does not exceed the budget
- **AND** the provider counts only sources included in the result

### Requirement: Optional expansion uses current note evidence

When expansion is configured with a byte budget, the provider SHALL fetch current content for selected notes and expand around search evidence within a per-note character limit. Source freshness SHALL come from the fetched note. Retrieval errors SHALL follow the existing recall failure behavior.

#### Scenario: Relevant phrase near the end of a long note

- **GIVEN** keyword search returns a snippet matching a phrase near a long note's end
- **WHEN** expansion is enabled
- **THEN** the expanded evidence contains the matching phrase and surrounding content within the configured limits
