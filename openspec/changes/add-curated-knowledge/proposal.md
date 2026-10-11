## Why

Robot Notes stores shared knowledge, but accepted notes currently have no retained revisions or proposal workflow. Agents need to suggest evidence-backed changes while humans retain authority over conflicts and consequential decisions.

## What changes

- Designate ordinary notes as curated knowledge without replacing Markdown, the editor, folders, or databases.
- Add stable block identity, comments, proposals, and retained accepted revisions.
- Enforce separate proposal, review, direct-edit, policy-management, and purge permissions.
- Inherit access and approval policy through folders, with note overrides.
- Keep normal recall limited to accepted knowledge; expose proposals explicitly for review and gardening.
- Require human approval by default. Permit explicit, conservative automatic acceptance of eligible evidence-backed changes.

## Capabilities

### New capabilities

- `curated-knowledge`: block proposals, inherited policies, review decisions, accepted history, and accepted-only recall.

### Modified capabilities

Implementation changes to notes storage, APIs, authorization, search, and the Flutter client will be specified in their respective issue PRs. This change records the shared contract before those dependent implementations.

## Impact

The server will own authorization and acceptance. REST, MCP, WebSocket subscriptions, search, and database views must apply the same effective policy. The Flutter app will add review and history views beside its existing editing flow. Hermes will propose changes to curated knowledge and recall accepted content.

## Non-goals

Block-level permission overrides, autonomous gardening agents, semantic truth scoring, a replacement editor, a context engine, and automatic evidence archiving are outside the first implementation. The design leaves extension points for them.
