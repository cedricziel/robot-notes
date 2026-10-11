# Note revision history

Set the note property `history` to `true` through the existing create, update, or property-patch API to retain accepted revisions. Capture starts with that write and the previous current version when available. Ordinary notes remain unchanged.

All endpoints use the usual bearer credential and optional `X-Vault-Id` header:

| Request | Behavior |
| --- | --- |
| `GET /notes/{id}/history` | Returns `{ "revisions": [...] }`, ordered oldest first, including Markdown snapshots and deletion tombstones. Requires `notes:read`. |
| `POST /notes/{id}/history` | Restores `{ "version": 1, "if_match": 3 }` as a new accepted version. Requires `notes:write`. |
| `DELETE /notes/{id}/history` | Permanently removes retained snapshots and tombstones. Requires the administrative key, or both `notes:write` and `vaults:manage`. |

Restore preserves the note ID. `if_match` must equal the latest current version or deletion tombstone version. A stale version or occupied historical path returns 409. A missing retained version returns 404. A conflicting editor lock returns 423. Invalid current-schema properties and database-definition restores return 422.

History has no expiry. Normal deletion removes the current note from search but retains its history and a tombstone. Purge removes that recovery path. Purging a live note leaves its current content intact: if `history: true` remains set, the next write resumes capture, including the current baseline. To stop future capture, unset that property and then purge. Removing the property alone does not stop existing history capture.

Snapshots reside in `<contentDir>.history`; include this directory in backups. Purge cannot erase existing backups or downloaded copies. External Markdown edits are not audited. The server recovers pending writes before indexing after a restart, so an interrupted request may have taken effect. Reread the note and history before retrying.

Actor fields preserve attribution when supplied by the write service. They do not distinguish human approval from agent activity. This API does not implement curated-note approval policies or pending proposals.
