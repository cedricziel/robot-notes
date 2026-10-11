## ADDED Requirements

### Requirement: Exact entry corrections
The provider SHALL prefer the host's committed metadata.previous_content over legacy old_text, SHALL preserve complete multiline entries and unrelated content, and SHALL not append an unmatched or ambiguous replacement as a new active claim.

#### Scenario: Strong committed entry resolves an ambiguous selector
- **WHEN** the host supplies the exact previous entry and a weaker selector matches several entries
- **THEN** the complete selected entry is replaced
- **AND** identical superseded copies are not left active

#### Scenario: No safe correction target
- **WHEN** the selected entry cannot be identified safely
- **THEN** accepted content is unchanged
- **AND** operation health reports a review requirement rather than success

### Requirement: Curated agent writes are proposals
The provider SHALL query existing or prospective effective permissions and SHALL submit institutional or curated writes as proposals even when using legacy operator credentials. The SDK SHALL declare restrictive runtime agent origin without granting authority.

#### Scenario: Native curated deletion
- **WHEN** an explicit forget call targets a curated note
- **THEN** a versioned whole-note deletion proposal is submitted
- **AND** the result reports its actual proposal state and accepted flag

#### Scenario: Unsupported institutional API
- **WHEN** permissions or proposal APIs are unavailable for an explicitly institutional or observed curated target
- **THEN** the provider fails closed instead of performing an accepted direct write
- **AND** ordinary personal legacy writes can retain their existing API path

### Requirement: Provenance uses accepted block metadata and proposals
The provider SHALL retain supplied source coordinates and prior accepted block revision references in curated proposals. Missing lineage SHALL be explicit unknown. It SHALL NOT fabricate archive digests, derive source IDs from a later session, stash truth metadata in arbitrary note properties, or build a second knowledge store.

#### Scenario: Ordinary personal provenance
- **WHEN** a personal write uses the unmanaged accepted API
- **THEN** the outcome reports source_unknown true
- **AND** callback lineage is not represented as managed accepted provenance

### Requirement: Frozen prepared effects survive replay
The provider SHALL persist precise prepared effects and idempotency keys before RPC, SHALL validate legacy prepared corrections before replay, and SHALL not reselect or silently rebase ambiguous acknowledged effects.

#### Scenario: Lost proposal acknowledgement
- **WHEN** a submitted proposal is retried after restart
- **THEN** the same frozen target, operations, references, and idempotency key are sent
- **AND** accepted text is not directly modified

#### Scenario: Ordinary destination becomes curated
- **WHEN** a frozen ordinary operation's designation changes before its write
- **THEN** the operation is denied or blocked rather than silently accepted as an institutional write

### Requirement: Accepted block coordinates are exact
The provider SHALL require matching note and block-map versions and hashes, SHALL decode UTF-16 coordinates correctly, and SHALL refuse ambiguous anchors and unmapped-gap edits.

#### Scenario: Source moves or map changes
- **WHEN** a note moves from the configured destination or its accepted map fails freshness validation
- **THEN** the provider does not edit another scope or guess block identities
