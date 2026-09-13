## Purpose

Defines the observable behavior of a Hermes Agent `MemoryProvider` plugin that uses a robot-notes workspace as Hermes' external memory backend, covering activation, recall, and the sparse set of paths through which the plugin writes notes.

## ADDED Requirements

### Requirement: Plugin activates only when fully configured

The plugin SHALL report itself available only when a robot-notes base URL and API key are both configured; it SHALL NOT make a network call to determine availability. When either value is missing, Hermes SHALL be told the plugin is unavailable along with a human-readable reason naming the missing setting.

#### Scenario: Fully configured

- **WHEN** both the base URL and API key are configured
- **THEN** the plugin reports itself available without making a network request

#### Scenario: Missing API key

- **WHEN** the base URL is configured but the API key is not
- **THEN** the plugin reports itself unavailable and the reason names the API key as missing

### Requirement: Every robot-notes call is authenticated and attributed

Every request the plugin makes to robot-notes SHALL carry the configured API key as a bearer credential and SHALL identify the calling agent via the configured actor name.

#### Scenario: Requests carry credentials and actor

- **WHEN** the plugin calls robot-notes for any operation (recall, tool call, session-end write, or memory mirror)
- **THEN** the request carries the configured bearer API key and the configured actor name

### Requirement: Recall surfaces relevant notes before a turn

Before generating a response, the plugin SHALL search the robot-notes workspace using the upcoming user turn as the query and, when matches exist, inject a formatted summary of the top matches as recall context. Recall SHALL NOT block turn generation on a slow or failing robot-notes call — an empty or last-known-good result SHALL be used instead, and the turn SHALL proceed either way.

#### Scenario: Relevant note found

- **GIVEN** a note in the workspace matches the upcoming user turn
- **WHEN** the plugin performs recall for that turn
- **THEN** a formatted summary including that note's title and a snippet is injected as context

#### Scenario: No matches

- **WHEN** the plugin performs recall and the search returns no matches
- **THEN** no recall context is injected and the turn proceeds normally

#### Scenario: robot-notes unreachable during recall

- **WHEN** the plugin performs recall and the robot-notes server does not respond
- **THEN** the turn proceeds without recall context and no error is surfaced to the conversation

### Requirement: Explicit tools let the model search and manage notes on demand

The plugin SHALL expose tools the model can call directly to search the workspace, fetch a specific note, store a new fact as a note, and delete a note it created. Each tool SHALL map to the corresponding robot-notes operation and SHALL return the same not-found/validation outcomes robot-notes itself returns, translated into a tool-call error rather than a crash.

#### Scenario: Search tool returns matches

- **WHEN** the model calls the search tool with a query
- **THEN** the result lists matching notes with title, id, and snippet

#### Scenario: Remember tool stores a fact

- **WHEN** the model calls the remember tool with a title and content
- **THEN** a new note is created in the workspace and its id is returned to the model

#### Scenario: Fetch tool on unknown id

- **WHEN** the model calls the fetch tool with an id that does not exist in the workspace
- **THEN** the tool call result is an error rather than an unhandled exception

### Requirement: Memory writes are sparse, not per-turn

The plugin SHALL NOT write a note for every conversation turn. It SHALL write to robot-notes only in these cases: at the end of a session, when the model explicitly calls a note-writing tool, or when Hermes' own built-in memory is written to.

#### Scenario: Ordinary turn produces no write

- **WHEN** a turn completes without the model calling a note-writing tool and the session has not ended
- **THEN** no note is created or modified in the workspace as a result of that turn

### Requirement: Each session gets one durable summary note

At the end of a session, the plugin SHALL create or update exactly one note representing that session's summary, filed under a fixed, predictable location keyed by the session identifier. Ending the same session more than once (for example on resume) SHALL update that same note rather than creating a duplicate.

#### Scenario: First session end creates the note

- **WHEN** a session ends for the first time
- **THEN** exactly one new note is created for that session, filed under the fixed session-notes location

#### Scenario: Resumed session updates the same note

- **GIVEN** a session's summary note already exists
- **WHEN** that same session ends again
- **THEN** the existing note is updated in place and no second note is created for that session

### Requirement: Built-in memory writes are mirrored into robot-notes

When Hermes' built-in memory (`MEMORY.md` or `USER.md`) is written to, the plugin SHALL apply the equivalent add, replace, or remove operation to a corresponding fixed robot-notes note, so the two memory stores stay in sync without requiring a per-turn write.

#### Scenario: Built-in memory addition is mirrored

- **WHEN** Hermes appends a new fact to its built-in memory
- **THEN** the corresponding robot-notes note is updated to include that same fact

#### Scenario: Built-in user-profile write is mirrored to a separate note

- **WHEN** Hermes writes to its built-in user profile rather than its general memory
- **THEN** the mirrored write lands in a separate, fixed robot-notes note dedicated to the user profile

### Requirement: Setup is driven by a declared configuration schema

The plugin SHALL declare its configuration fields (robot-notes base URL, actor name, and the API key as a secret) so Hermes' setup flow can collect and persist them without the user hand-editing files. The API key SHALL be stored as a secret and SHALL NOT be persisted alongside the non-secret fields.

#### Scenario: Setup collects all required fields

- **WHEN** a user runs the plugin's setup flow
- **THEN** they are prompted for the base URL, actor name, and API key, and completing it leaves the plugin available

#### Scenario: API key is not written to the plain config

- **WHEN** setup completes
- **THEN** the base URL and actor name are persisted in the plugin's config file and the API key is not present in that file
