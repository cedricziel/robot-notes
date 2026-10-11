## Why

Robot Notes stores shared knowledge, but accepted notes currently have no retained revisions or proposal workflow. Agents need to suggest evidence-backed changes while humans retain authority over conflicts and consequential decisions.

## What changes

- Designate ordinary notes as curated knowledge without replacing Markdown, the editor, folders, or databases.
- Support Person, Project, Claim, Decision, Procedure, and Evidence as typed Markdown entries.
- Bulk-adopt a pinned published Schema.org release and define local types and enforced constraints that extend its terms.
- Combine authoring guidance with enforced properties and typed relations for reliable accepted-knowledge queries.
- Separate original sources from curated knowledge and preserve revision-specific evidence references.
- Store imported and local type definitions as canonical filesystem documents with rebuildable indexes.
- Define versioned file formats and explicit artifact writers and server publication authority.
- Add adapter-neutral, durable background extraction from opt-in source capture into evidence-backed proposals.
- Expose shared agent tools for type discovery, accepted queries, source inspection, validation, and idempotent atomic proposals.
- Curate type definitions and preview schema migration impacts.
- Add stable block identity, comments, proposals, and retained accepted revisions.
- Enforce separate proposal, review, direct-edit, policy-management, and purge permissions.
- Inherit access and approval policy through folders, with note overrides.
- Keep normal recall limited to accepted knowledge; expose proposals explicitly for review and gardening.
- Require human approval by default. Permit explicit, conservative automatic acceptance of eligible evidence-backed changes.

## Capabilities

### New capabilities

- `curated-knowledge`: block proposals, inherited policies, review decisions, accepted history, and accepted-only recall, ontology adoption, reusable types, and typed relationships.

### Modified capabilities

Implementation changes to notes storage, APIs, authorization, search, and the Flutter client will be specified in their respective issue PRs. This change records the shared contract before those dependent implementations.

## Impact

The server will own authorization and acceptance. REST, MCP, WebSocket subscriptions, search, and database views must apply the same effective policy. The Flutter app will add review and history views beside its existing editing flow. Hermes and future adapters can opt into source capture; a server worker extracts proposals with no acceptance authority. Hermes recalls accepted knowledge.

## Non-goals

PROV-O provenance and SKOS concept organization are later extensions. Block-level permission overrides, autonomous gardening agents, semantic truth scoring, a replacement editor, a context engine, automatic evidence archiving, universal ontology reasoning, and arbitrary executable import rules are outside the first implementation. The design leaves extension points for them.
