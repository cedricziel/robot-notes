## Activation and retention
A note opts in through its `history: true` property. Existing defaults remain unchanged. Once history exists, removing that property does not erase history or stop capture. There is no automatic expiry. Explicit administrative purge removes retained revisions and tombstones. On a live note, purge leaves current content intact; `history: true` resumes capture on its next write, including the current baseline. A live note without that property stops capture after purge.

## Persistence and recovery
Snapshots live beside the content directory in `<contentDir>.history`, outside note discovery, uploads, and search. Note IDs become base64url directory names. A flushed pending record contains the intended canonical content, old and new paths, version, actor when available, and any missing baseline.

Commit order is durable pending intent, canonical replacement or deletion, immutable accepted snapshots, then pending removal. Pending records are not returned as accepted history. Startup completes them before scans. Each accepted note revision has a durable index-pending ticket until its derived index update succeeds. Acknowledgement removes only that revision's ticket, so another unindexed revision remains dirty. Startup rebuilds search if any ticket or legacy dirty marker remains and clears them only after the rebuild succeeds. An interrupted commit blocks note reads, history reads, scans, and mutations until restart, preventing reuse of paths reserved by its intent. A request interrupted after intent publication may take effect on restart; callers must reread state before retrying.

This guarantees recovery from process interruption. It does not claim protection against storage-device failure, directory-metadata loss after power failure, multiple server processes sharing a vault, or manual edits to journal files.

Purge writes a marker before recursive deletion so startup finishes an interrupted purge. Purge does not erase external backups or client copies. History captures writes made through Storage; external Markdown edits are not an audited write channel.

## Restore
Restore preserves the note ID and creates a version above the current note or deletion tombstone. It requires the latest version as `if_match`, checks title/path ownership, and refuses to overwrite another note. The write service refreshes current search, links, metadata, and events. Ordinary properties are checked against current database schemas. Database-definition restore returns 422 in this first implementation.

## Authorization and provenance
Existing middleware enforces vault grants and REST scopes: reads require `notes:read`; restores require `notes:write`. Purge additionally requires the static administrative key or `vaults:manage`. These permissions do not establish human identity or approval authority. Curated-note policy enforcement follows separately. Actor attribution retains the identity already resolved by the calling protocol; it does not elevate header labels into trusted identities.
