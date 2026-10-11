## Why

Automatic memory mirrors and readable session notes can fail while the server is unavailable. Their pending writes currently disappear on restart.

## What changes

- Add an optional bounded durable outbox for automatic mirrors and session notes.
- Freeze intended note content and its base version before delivery so lost acknowledgements do not reapply destructive selectors.
- Isolate queues by destination and credential, restrict replay to primary write contexts, and expose queue status through existing memory health.

## Impact

The `durable_writes` configuration defaults to false. Explicit tool calls retain their existing immediate error behavior. Evidence capture can reuse the generic outbox through its own separate channel.
