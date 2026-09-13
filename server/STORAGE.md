# robot-notes server storage layout

The filesystem **is** the database. Markdown is the canonical source
of truth; SQLite FTS5 is treated as a derived cache that the server
rebuilds on demand. This file documents the on-disk layout, the
frontmatter schema, the atomicity story, and the invite store.

For the authoritative behaviour see the specs at
`openspec/specs/notes-storage/spec.md`, `.../links/spec.md`, and
`.../agent-onboarding/spec.md` (and, for the change that introduced
the vault layout, `openspec/changes/add-vault-structure/`).

---

## Layout under `--data-dir`

By default `--data-dir` is `./data`; in the container image it is
`/data` (declared as a `VOLUME`).

```
data/
├── content/                     # one markdown file per note, nested by folder
│   ├── Inbox.md                 # a root-level note
│   ├── Projects/
│   │   ├── Project Alpha.md
│   │   └── Alpha/
│   │       └── Meeting Notes.md
│   └── …
├── invites/                     # one JSON file per invite
│   ├── 01HM2C...token.json
│   └── …
└── search.db                    # SQLite FTS5 index + link/tag data (rebuildable)
```

The directory must exist and be writable by the server's UID
(`10001` in the published Docker image). The server creates
`content/` and `invites/` lazily on the first write.

---

## Note files

### Filename and path

```
data/content/<path>/<sanitized-title>.md
```

`<path>` is the note's folder, using `/` as the separator; a
root-level note has no folder segment (`data/content/<title>.md`).
`<sanitized-title>` is the note's `title` with the characters
`\ / : * ? " < > |` stripped, then normalized to Unicode NFC. The
note's `id` (a ULID) no longer appears in the filename — it is a
permanent frontmatter field and the sole API address (`/notes/{id}`
never changes even when the note is renamed or moved). Folder and
filename comparisons for collision detection are case-insensitive
(to match macOS/Windows' default case-insensitive filesystems), and
the underlying create/rename/move is serialized per normalized target
path so two concurrent operations that would resolve to the same file
can't silently clobber each other — exactly one succeeds, the other
gets a `path_conflict`.

Changing a note's `title` renames its file in place; changing its
`path` moves it to the new folder (creating intermediate directories
as needed). Both go through the same tmp+fsync+rename atomicity as
any other write. A folder is never deleted just because it becomes
empty.

### Empty-folder markers

```
data/content/<path>/.folder
```

A folder created with no notes in it (via `POST /notes/tree`, see
`API.md`) is made durable by an empty marker file named `.folder`
written directly inside it. The marker carries no `.md` extension, so
it is never treated as a note by any scan: it is excluded from
`GET /notes`, `GET /search`, link parsing, and tag computation. On
startup the same recursive walk that indexes `content/**/*.md` also
looks for `.folder` files and registers each one's parent directory as
a known-empty folder, so `GET /notes/tree` continues to report it
after a restart even though it holds no notes.

The marker is written only if the folder had zero notes at the moment
it was created, and it is never removed automatically — creating a
note inside a marked folder leaves the marker in place alongside it,
and deleting that note again does not resurrect or re-create a marker.
If you filter dotfiles out of a backup or sync tool, an empty folder
created this way can silently stop being reported after a restore;
this is a cosmetic loss (the folder just needs to be re-created empty,
or gets a note back once one is added), not a data-loss risk.

### File body

A note file is YAML frontmatter followed by an empty line and the
markdown body:

```markdown
---
id: "01HM2AKEXR..."
title: "Meeting notes — Wed"
path: "Projects/Alpha"
version: 7
created_at: "2026-04-25T10:14:23Z"
updated_at: "2026-04-25T10:42:11Z"
---

# Wednesday

- Bob said … see [[Project Alpha]] for background. #standup
```

The frontmatter delimiter is `---` on its own line at the start and
end. Anything outside the delimiters is treated as the body.

Note content may contain `[[Title]]` / `[[Title|Alias]]` inline links
(see "Links" below) and `#tag` / `#parent/child` inline tags (see
"Tags" below) as plain text — nothing about the file format changes
to support them, which is what keeps the vault readable and editable
by other Markdown tools, including Obsidian itself, pointed directly
at `data/content/`.

### Frontmatter schema

| Field        | Type            | Required | Notes                                                                                                     |
| ------------ | --------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `id`         | ULID            | yes      | Permanent; does **not** appear in the filename.                                                           |
| `title`      | string          | yes      | May be empty. Drives the filename.                                                                        |
| `path`       | string          | yes      | Folder, `/`-separated, no leading/trailing slash. Empty string = vault root. Drives the parent directory. |
| `version`    | integer         | yes      | Monotonically increasing per note. Starts at `1` on creation.                                             |
| `created_at` | ISO-8601        | yes      | UTC, timezone `Z`. Set once at create time.                                                               |
| `updated_at` | ISO-8601        | yes      | UTC, timezone `Z`. Updated on every successful PUT.                                                       |
| `tags`       | list of strings | no       | Optional. Merged with inline `#tag` tokens from the body — see "Tags" below.                              |

The server rejects loads where `version`/timestamps are missing or
unparseable. Unknown frontmatter keys round-trip unchanged.

### Migrating from the flat `<id>.md` layout

Servers upgraded from before the vault-structure change stored notes
flat, at `data/content/<id>.md`, with no `path` key. On startup, before
building the metadata index, the server detects any such file (name
matches a ULID, frontmatter has no `path`), assigns it `path: ""`, and
renames it to `<sanitized-title>.md` at vault root — de-duplicating a
colliding name by appending ` (2)`, ` (3)`, etc., checked against every
note that will exist after migration (not just other files being
migrated in the same run), processed in ascending-id (creation) order
for determinism. This is automatic and requires no operator action; a
file that fails to migrate is logged and left in its legacy form
rather than blocking startup.

---

## Links

A note's outgoing links are parsed from `[[Title]]` and
`[[Title|Alias]]` occurrences in its body on every write and on
startup index rebuild — this is plain text, not a special file
format, so the same content is a valid link in a real Obsidian vault
too. `[[Title#Heading]]` is not given heading-anchor treatment in this
version; the whole bracketed text is treated as the title.

Links resolve against a live title→id index. A link to a title that
doesn't currently exist is a valid "phantom" link, not an error — it
resolves automatically once a note with that exact title is created,
without the linking note being re-saved. If two notes share a title,
resolution picks whichever id sorts first (ascending) and logs a
warning; this is a known v1 limitation, not fully solved.

Renaming a note rewrites `[[OldTitle]]`/`[[OldTitle|Alias]]` (preserving
any alias) to the new title in every other note whose _parsed_ links
reference the old title — an incidental plain-text mention of the old
title outside `[[...]]` is left untouched. Each rewrite is pushed
through the normal write path (own version bump, search/meta-index
update, `changed` broadcast attributed to the actor who did the
rename), and is skipped — with a logged warning, not forced — for a
note currently locked by a different actor.

`GET /notes/{id}/backlinks` and `GET /notes/{id}/links` (see `API.md`)
expose this data over HTTP; the underlying reverse index (which notes
link to a given title) lives in `search.db`, not in any note's
frontmatter, since it's fully derivable from content on a rebuild.

---

## Tags

A note's tag set is the union of its frontmatter `tags: [...]` array
(if present) and any `#tag` / `#parent/child` tokens found in its body
(alphanumeric, `-`, `_`, `/`). Matching is case-insensitive; the tag is
displayed in whichever casing was first seen (frontmatter order first,
then body occurrence order). The tag set is recomputed on every write
and rebuild — it is derived, read-only data, never written back into
the frontmatter `tags` array.

---

## Atomic writes

Every note (and every invite) is written via the
**tmp + fsync + rename** pattern:

1. Write the new content to `data/content/<path>/<title>.md.tmp.<pid>.<rand>`.
2. `fsync` the temp file.
3. `rename` over the destination — POSIX guarantees this is atomic
   on the same filesystem.
4. `fsync` the parent directory so the rename survives a crash.

This means concurrent observers always see either the old file or the
new file in full — never a half-written one — and that a crash
between steps 2 and 3 leaves the previous version intact.

Concurrent writes to the **same** note are serialized through an
in-memory mutex keyed by note id; the optimistic-concurrency layer
(`If-Match`) handles the user-facing conflict surface. Concurrent
writes that would resolve to the **same target path** (e.g. two
different notes renamed to the same title in the same folder at the
same time) are separately serialized through a mutex keyed by the
normalized target path, so one gets `path_conflict` instead of
silently overwriting the other's file.

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

`data/search.db` is a SQLite FTS5 database keyed by note id, indexing
`title`, `path`, `content`, and the computed tag set, plus a
`link_edges` table (`source_id`, `target_title`, `target_id`,
`resolved`) recording every note's outgoing links — this is what
backs `GET /notes/{id}/backlinks`/`links` and the `path`/`tag` filters
on `GET /search` and `GET /notes`. It is **always rebuildable** from
`data/content/`:

- Missing → the server scans `content/**/*.md` (recursively) on
  startup and rebuilds.
- Corrupt → the server detects on open, deletes, and rebuilds.
- Schema-version mismatch → the server drops and rebuilds. A
  pre-vault-structure `search.db` (lacking `path`/tags/`link_edges`)
  counts as a schema mismatch and is rebuilt automatically.

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

| State   | `burned_at`        | What it means                                                                                 |
| ------- | ------------------ | --------------------------------------------------------------------------------------------- |
| Pending | `null`             | Not yet fetched; URL is still usable until `expires_at`.                                      |
| Burned  | `<timestamp>`      | First successful `GET /invites/<token>/onboarding.txt`. Subsequent fetches return `410 Gone`. |
| Revoked | n/a (file deleted) | Operator-initiated cancellation via `DELETE /invites/<token>`.                                |

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
