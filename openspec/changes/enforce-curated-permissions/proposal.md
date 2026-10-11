# Enforce curated knowledge permissions

## Why

Issue #369 requires accepted curated content, policy changes, and purge to be authorized independently of ordinary note writes. Authentication middleware alone cannot protect source-reading mutations, indirect renames, uploads, historical reads, or event delivery.

## What changes

Add a server-owned hierarchical policy store, trusted principal capabilities, capability inspection and conditional policy endpoints, and enforcement across REST, MCP, WebSockets, storage-facing writes, and source reads. Initialize required accepted history before designation and preserve the live current block map during purge. The proposal workflow remains issue #371.

## Impact

Ordinary notes keep their default workflows, but accepted writes require read access as well as write access. Scoped agents and restrictive agent-origin requests use proposals for curated changes. See `docs/curated-knowledge-permissions.md` for API and migration details.
