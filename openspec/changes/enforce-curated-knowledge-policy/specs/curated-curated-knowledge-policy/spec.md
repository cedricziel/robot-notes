## Purpose

Verify reuse of the existing curated policy implementation at new knowledge service boundaries without introducing duplicate enforcement semantics.

## ADDED Requirements

### Requirement: New services reuse existing enforcement

New type review, source ingestion, proposal, query, and extraction operations SHALL use the existing credential-derived policy service. Existing policy and adapter behavior from `enforce-curated-permissions` SHALL remain unchanged unless a demonstrated regression requires a tested fix.

#### Scenario: New operation lacks authority

- **WHEN** a caller invokes a new knowledge service operation without its required capability or effective scope
- **THEN** the service SHALL deny it through existing policy semantics without bypassing enforcement through an ordinary write

### Requirement: Regression verification gates integrated release

Release verification SHALL record existing policy regressions and authorization coverage of every enumerated new boundary. Proposal review SHALL consume the already merged enforcement foundation without requiring a replacement resolver.

#### Scenario: Audit discovers a protection gap

- **WHEN** a new endpoint fails an authorization regression
- **THEN** release verification SHALL remain incomplete until a focused fix and regression pass against the existing enforcement service
