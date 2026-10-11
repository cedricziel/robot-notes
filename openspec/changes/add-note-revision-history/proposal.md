## Why
Note versions detect concurrent writes but do not retain replaced or deleted content. Opt-in history gives memory-bearing notes a recovery path without changing ordinary-note defaults.

## What Changes
Retain accepted revisions for notes with `history: true` properties. Add vault-scoped inspection, restore, and administrative purge. Recover interrupted filesystem commits before indexing.

## Non-goals
Block identity, proposals, human approval roles, automatic expiry, database-definition restoration, and Flutter history UI are separate work.

## Impact
Storage and shared note writes retain snapshots. REST exposes `/notes/{id}/history`. Search rebuilds after a history commit when the process restarts. Addresses #349.
