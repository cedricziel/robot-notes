## Why

Readable conversation notes omit tool results and truncate long text. Hermes compression also drops information, so recovering supported evidence requires a separate durable archive before compression.

## What changes

- Add per-vault immutable JSON evidence with independent retention and administrative purge.
- Capture supplied completed-turn messages in an opt-in durable queue and archive them outside ordinary notes and search.
- Require durable remote acknowledgement before reporting checkpoint API v2 success.
- Document the pinned Hermes host's normalized evidence checkpoint and supported JSON-only evidence.

## Impact

Adds `/evidence/{digest}` to authenticated vault-scoped REST routing. The archive is disabled by default. It provides evidence for inspection and future proposal provenance, without accepting observations as curated knowledge.
