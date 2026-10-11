## ADDED Requirements

### Requirement: Reproducible semantic tail experiment
The evaluation SHALL use synthetic sources, an isolated loopback model provider and disposable vaults, and SHALL verify the pinned model digest, provider version, and tokenizer artifact before recording measurements.

#### Scenario: Paraphrased tail evidence exceeds embedding input
- **WHEN** the corpus contains supporting text beyond the whole-note provider input limit
- **THEN** the report compares keyword and current whole-note hybrid evidence injection with the same source labels and scope
- **AND** records actual token counts with the named pinned tokenizer, indexing completion, request truncation, and warm query latency

### Requirement: Measurement-gated passage prototype
The evaluation SHALL run the bounded passage prototype only when the whole-note baseline shows an evidence recall gap. The prototype SHALL preserve source note identity, revision freshness, scope, note-level deduplication, and an explicit context bound.

#### Scenario: Source changes after passage indexing
- **WHEN** a source note revision changes before prototype evidence injection
- **THEN** the obsolete passage is rejected
- **AND** the report does not count returned note identity alone as recovered evidence

#### Scenario: Retrieval tradeoffs persist
- **WHEN** a passage experiment recovers tail evidence while increasing cost or returning superseded or irrelevant sources
- **THEN** the report records those outcomes and states a production go/no-go decision
- **AND** production indexing is unchanged
