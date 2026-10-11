## Design tasks

- [x] Confirm memory stages and optional evidence capture.
- [x] Confirm block review, accepted-only recall, concurrent merging, and direct human editing.
- [x] Confirm server permissions, folder inheritance, and explicit-purge history retention.
- [x] Inspect storage, editor, search, REST, MCP, and WebSocket integration points.
- [x] Record requirements and create focused implementation issues.
- [x] Validate the OpenSpec change with strict validation.
- [x] Review the written contract and prepare the design PR.

## Typed knowledge planning tasks

- [x] Confirm entities and knowledge objects with Person, Project, Claim, Decision, Procedure, and Evidence as starting types.
- [x] Record authoring guidance, enforced constraints, and custom extensions of established schemas.
- [x] Record bulk adoption of a pinned published Schema.org release, import previews, version pinning, and reviewed upgrades.
- [x] Scope initial local types and constraints over Schema.org, with PROV-O and SKOS as later extensions.
- [x] Record accepted typed relations, validation, access-filtered queries, and migration safety.
- [x] Validate the expanded OpenSpec change with strict validation.

## Implementation tracking

Implementation is tracked in the issue sequence in `design.md`, with one PR per issue. The typed knowledge extension still needs focused implementation issues; the checked planning tasks do not indicate runtime completion. No runtime implementation is included in this design change.

## Definition of done

The agreed decisions appear as testable requirements, pending proposals are excluded from normal recall, authorization and crash-recovery obligations are explicit, ontology adoption and typed knowledge requirements are testable, schema evolution preserves accepted entries, and strict OpenSpec validation passes. The PR links the implementation issues without marking them complete.
