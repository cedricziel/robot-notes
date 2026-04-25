# robot-notes server storage layout

The filesystem **is** the database. Markdown is the canonical source
of truth; SQLite FTS5 is treated as a derived cache that the server
rebuilds on demand. This file documents the on-disk layout, the
frontmatter schema, the atomicity story, and the invite store.

For the authoritative behaviour see the specs at
`openspec/changes/add-mvp-foundation/specs/notes-storage/spec.md` and
`.../agent-onboarding/spec.md`.

---

## Layout under `--data-dir`

By default `--data-dir` is `./data`; in the container image it is
`/data` (declared as a `VOLUME`).

```
data/
├── content/                     # one markdown file per note
│   ├── 01HM2AKEXR....md
│   ├── 01HM2AM3Q9....md
│   └── …
├── invites/                     # one JSON file per invite
│   ├── 01HM2C...token.json
│   └── …
└── search.db                    # SQLite FTS5 index (rebuildable)
```

The directory must exist and be writable by the server's UID
(`10001` in the published Docker image). The server creates
`content/` and `invites/` lazily on the first write.

---

## Note files

### Filename

```
data/content/<ULID>.md
```

The `<ULID>` is also the `id` field in the API and the canonical
identifier the WebSocket events refer to. ULIDs are sortable, so a
naïve `ls` lists notes in creation order.

### File body

A note file is YAML frontmatter followed by an empty line and the
markdown body:

```markdown
---
id: 01HM2AKEXR...
title: Meeting notes — Wed
version: 7
created_at: 2026-04-25T10:14:23Z
updated_at: 2026-04-25T10:42:11Z
---

# Wednesday

- Bob said …
```

The frontmatter delimiter is `---` on its own line at the start and
end. Anything outside the delimiters is treated as the body.

### Frontmatter schema

| Field        | Type     | Required | Notes |
| ------------ | -------- | -------- | ----- |
| `id`         | ULID     | yes      | Must equal the filename stem. |
| `title`      | string   | yes      | May be empty. |
| `version`    | integer  | yes      | Monotonically increasing per note. Starts at `1` on creation. |
| `created_at` | ISO-8601 | yes      | UTC, timezone `Z`. Set once at create time. |
| `updated_at` | ISO-8601 | yes      | UTC, timezone `Z`. Updated on every successful PUT. |

The server rejects loads where `id` disagrees with the filename, or
where `version`/timestamps are missing or unparseable.

---

## Atomic writes

Every note (and every invite) is written via the
**tmp + fsync + rename** pattern:

1. Write the new content to `data/content/<ULID>.md.tmp.<pid>.<rand>`.
2. `fsync` the temp file.
3. `rename` over the destination — POSIX guarantees this is atomic
   on the same filesystem.
4. `fsync` the parent directory so the rename survives a crash.

This means concurrent observers always see either the old file or the
new file in full — never a half-written one — and that a crash
between steps 2 and 3 leaves the previous version intact.

Concurrent writes to the **same** note are serialized through an
in-memory mutex keyed by note id; the optimistic-concurrency layer
(`If-Match`) handles the user-facing conflict surface.

---

## Out-of-band edits are not supported

The server treats `data/content/` as private state for the lifetime
of a process. Editing a markdown file with another tool while the
server is running results in undefined behaviour:

- The in-memory metadata index will be stale.
- The FTS5 index will be stale.
- Subsequent PUTs will compute the `If-Match` baseline from the
  in-memory state and may overwrite your changes.

If you need to edit notes outside the server, stop the server first
and let it rebuild on the next start.

---

## Search index (`search.db`)

`data/search.db` is a SQLite FTS5 database keyed by note id. It is
**always rebuildable** from `data/content/`:

- Missing → the server scans `content/*.md` on startup and rebuilds.
- Corrupt → the server detects on open, deletes, and rebuilds.
- Schema-version mismatch → the server drops and rebuilds.

Rebuilds run synchronously during startup so the server is never
serving requests against a known-bad index. Routine writes (POST,
PUT, DELETE) update the index in the same transaction as the file
write.

You may safely delete `search.db` at any time when the server is
stopped — it will rebuild the next time it starts.

---

## Invite store

```
data/invites/<TOKEN>.json
```

Each invite is a single JSON file:

```json
{
  "token": "…opaque…",
  "label": "research-bot",
  "created_at": "2026-04-25T10:14:23Z",
  "expires_at": "2026-04-26T10:14:23Z",
  "single_use": true,
  "burned_at": null
}
```

Lifecycle:

| State | `burned_at` | What it means |
| ----- | ----------- | ------------- |
| Pending | `null` | Not yet fetched; URL is still usable until `expires_at`. |
| Burned  | `<timestamp>` | First successful `GET /invites/<token>/onboarding.txt`. Subsequent fetches return `410 Gone`. |
| Revoked | n/a (file deleted) | Operator-initiated cancellation via `DELETE /invites/<token>`. |

Writes use the same tmp+fsync+rename pattern as note files; the
in-memory index is updated atomically with the file.

Expired invites are not auto-deleted. They simply return
`410 invite_expired` and are visible in `GET /invites` for audit.
Operators may sweep them with a periodic
`DELETE /invites/<token>` if needed.

---

## Backup story

Because the filesystem is the source of truth and `search.db` is
rebuildable, a working backup is just a snapshot of `data/content/`
and (optionally) `data/invites/`. Restore = drop the directory in
place and start the server; the FTS index builds itself on first
boot.

For the production container this maps cleanly to whatever volume
backup primitive your platform offers (Restic, `zfs send`, EBS
snapshots, etc.).
