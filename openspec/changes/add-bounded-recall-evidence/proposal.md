## Why

Automatic recall has no configurable task folder or context-size bound. Short snippets omit surrounding evidence and source freshness. Issue #347 requests scoped, bounded evidence without a context engine.

## What changes

- Add an optional task folder that intersects configured identity roots within the selected vault.
- Add an optional total UTF-8 byte budget covering evidence and source metadata.
- Expand search snippets from current note content when explicitly configured, and include note IDs and update timestamps.
- Preserve existing unconfigured recall behavior.

## Impact

Changes affect Hermes recall configuration and formatting. No server schema, embedding model, authentication, or proposal approval behavior changes. The keyword baseline already demonstrates tail evidence retrieval. Semantic passage indexing remains unproven by that baseline and requires a separate model-backed experiment.
