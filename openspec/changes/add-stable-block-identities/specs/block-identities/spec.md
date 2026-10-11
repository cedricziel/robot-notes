## ADDED Requirements

### Requirement: Exact accepted Markdown
The server SHALL preserve the exact Markdown body while deriving conservative top-level block spans with UTF-16 source offsets. Identity metadata SHALL remain outside canonical Markdown and ordinary search.

#### Scenario: Complex source round trip
- **WHEN** accepted content contains CRLF, Unicode, repeated whitespace, lists, tables, code fences, or embedded constructs
- **THEN** the content remains exactly unchanged and compound constructs are not split into speculative inner anchors

### Requirement: Persistent block identity
Accepted history SHALL retain opaque block IDs and per-block revisions. Unchanged and unambiguously moved blocks SHALL keep identity. An unambiguous single-block edit SHALL increment its block revision. Ambiguous correspondence SHALL retire affected identities and report that anchors require re-review.

#### Scenario: Repeated text changes
- **WHEN** a changed document contains indistinguishable repeated blocks
- **THEN** the server assigns fresh IDs to ambiguous spans rather than guessing their correspondence

#### Scenario: Split or merge
- **WHEN** a whole-note save splits or merges existing blocks
- **THEN** affected old IDs retire and resulting blocks receive new IDs

### Requirement: Recoverable accepted metadata
Candidate block maps SHALL commit through the accepted history journal with canonical content. Recovery SHALL preserve candidate IDs and replay before content inspection. Stale whole-note saves SHALL not change accepted maps. Legacy revisions without maps SHALL remain immutable.

#### Scenario: Interrupted save
- **WHEN** a save fails after canonical publication but before accepted snapshot publication
- **THEN** inspection fails until restart and recovery publishes the same intended block IDs

### Requirement: Authenticated block inspection
Current and retained block maps SHALL require existing note read and vault authorization. Pending data SHALL not appear as accepted metadata. Purge SHALL erase retained block maps with history.

#### Scenario: Inspect a legacy revision
- **WHEN** an authorized reader requests an accepted revision recorded before block metadata existed
- **THEN** the server reports that its block map is unavailable without rewriting the revision
