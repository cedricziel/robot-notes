## Snapshot and identity

The provider serializes a JSON object with `session_id`, `kind`, `messages`, and `capture`. It sorts object keys, emits UTF-8 without ASCII escaping, uses compact separators, and rejects non-finite numbers. SHA-256 of those exact UTF-8 bytes identifies the immutable snapshot. Stable message IDs stay in supplied messages. Identical callbacks deduplicate, including after restart. Without distinct message IDs, two identical message lists in the same session represent one snapshot. This is snapshot capture, not an exact event timeline.

`sync_turn` preserves supplied JSON message objects, including tool content, structured message parts, and URL references. It does not fetch referenced media or support Python objects that cannot be serialized as JSON. Missing `messages` produces an explicitly marked `text_fallback` snapshot containing only the supplied user and assistant text.

## Host checkpoint contract

The pinned Hermes host hands checkpoint API v2 providers normalized user and assistant evidence. It removes tool rows, system messages, summaries, and assistant tool-call wrappers without prose. Surviving JSON message content is retained. A checkpoint cannot restore those omissions. Raw completed-turn snapshots are queued independently before compression, and the provider must flush them before acknowledging the normalized evidence checkpoint. Capture does not prove a complete conversation when the host omits raw messages or never invokes a completed-turn callback.

The provider advertises v2 only when archive capture is enabled, writes are permitted in the primary context, the REST client exists, and the evidence queue is initialized. Remote failures, malformed acknowledgements, queue loss, or undelivered raw evidence raise rather than acknowledge success. This lets the host retain its uncompressed context.

## Durable storage and erasure

Each vault has a separate `evidence.db` outside accepted content and search indexes. SQLite uses a rollback journal, `synchronous=FULL`, and secure deletion. PUT validates the digest, JSON snapshot structure, and retention between 1 and 3650 days. It acknowledges only after the database commit returns. First-write lineage and expiry survive retries.

GET returns retained evidence until its expiry. Expiry and operator DELETE erase payload and lineage while preserving a digest tombstone, so delayed retries cannot resurrect erased evidence. Expired payloads are removed at startup, during archive operations, and by an hourly sweep. DELETE requires the administrative static key. Existing REST `notes:read` and `notes:write` scopes govern inspection and capture within the credential's vault grant. Human approval roles are defined in the curated knowledge authorization foundation, outside this change.

## Local retry channel

Evidence uses the generic durable outbox through a separate destination queue. The destination includes server, vault, actor, credential hash, and available memory scope identity. Pending raw snapshots survive restart and retain their captured session and lineage. Repeated pending digests retain the first queued operation without consuming more capacity or extending its expiry. Queue capacity is 1000 operations and 32 MiB. Local retention follows the configured evidence retention days. Expired queued operations or failed local captures prevent checkpoint success; the provider does not pretend that a normalized evidence checkpoint substitutes for lost raw evidence.
