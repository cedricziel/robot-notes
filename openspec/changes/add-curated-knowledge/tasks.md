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

## Review follow-up planning tasks

- [x] Record explicit source and knowledge roles and revision-specific evidence references.
- [x] Record canonical filesystem type documents, candidate external edits, and offline rebuilds.
- [x] Define minimum required fields and relation constraints for all six starting types.
- [x] Require complete candidate validation, including removals and replacements.
- [x] Require transactional relation integrity across concurrent acceptance, deletion, and migration.
- [x] Validate and review the expanded contract.

## File and extraction planning tasks

- [x] Define versioned Markdown metadata, stable references, source blobs, and evidence locators.
- [x] Assign candidate writers and accepted server publication authority for each artifact.
- [x] Specify opt-in adapter capture and proposal-only background extraction.
- [x] Specify durable jobs, idempotent retries, multi-document proposals, and revocation checks.
- [x] Validate the file and extraction contract.
- [x] Update the PR with the file and extraction contract.

## Agent tool planning tasks

- [x] Define shared type discovery, queries, source inspection, validation, and proposal operations.
- [x] Define permission checks, query bounds, revision-aware results, and pagination semantics.
- [x] Define structured atomic groups, intra-group references, idempotency, and amendment history.
- [x] Validate the expanded tool contract.

## Hermes release planning tasks

- [x] Record existing memory compatibility, read-only behavior, and new tool capability discovery.
- [x] Define isolated Hermes and live-server verification as a runtime release gate.
- [x] Validate the expanded release contract.

## Implementation tracking

Implementation is tracked in the issue sequence in `design.md`, with one PR per issue. The typed knowledge extension still needs focused implementation issues; the checked planning tasks do not indicate runtime completion. No runtime implementation is included in this design change.

## Definition of done

The agreed decisions appear as testable requirements, pending proposals are excluded from normal recall, authorization and crash-recovery obligations are explicit, ontology adoption and typed knowledge requirements are testable, schema evolution preserves accepted entries, and strict OpenSpec validation passes. The PR links the implementation issues without marking them complete.


## Runtime release gate

Before enabling the feature in a release, the supported server and Hermes plugin pair must pass contract tests and isolated live-server verification covering existing memory behavior, the shared knowledge tools, opt-in capture, proposal-only extraction, authorized acceptance, and retry recovery. Record tested revisions and runtime versions. This is a future implementation obligation, not a completed task in this planning change.
