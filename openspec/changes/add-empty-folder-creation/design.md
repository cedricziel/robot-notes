## Context

See proposal.md - Why. Folders are a pure projection: `server/routes/notes/tree.dart` builds `{ folders: [{path, note_count}] }` entirely by grouping `MetaIndex.all` summaries by `.path` (`meta_index.dart`) — there is no on-disk or in-memory representation of a folder independent of the notes inside it. `note_path.dart` already provides NFC normalization, illegal-character stripping, and a case-insensitive `collisionKey` used by the existing move/rename/collision logic in `storage.dart`; this change reuses those helpers rather than adding new ones.

## Goals / Non-Goals

**Goals:**

- A folder can exist on disk and be reported by `GET /notes/tree` with zero notes in it, and survive a server restart.
- Reuse the existing path sanitization/normalization/collision primitives so an empty folder's path rules are identical to a note's `path` rules.

**Non-Goals:**

- No new persisted metadata store (database table, JSON index file, etc.) — the marker file itself, discovered by the existing startup scan, is the only new durable state.
- No change to `MetaIndex`'s note-keyed data model — empty folders are tracked in a small separate set, not folded into `NoteSummary`.

## Decisions

### An empty folder is represented by a marker file, not a new index/table

**Decision:** Write a hidden, empty marker file named `.folder` directly inside the folder's directory (e.g. `<data-dir>/content/Ideas/.folder`). The existing startup scan (`Storage`'s recursive walk that currently looks for `*.md`) also looks for `.folder` files and reports each one's parent directory (relative to `content/`) to `MetaIndex` as a known-empty folder.

**Why:** Every other piece of durable state in this app already lives on disk as a file the startup scan discovers (`notes-storage`: "the filesystem SHALL be the canonical source of truth"). A marker file is the smallest addition consistent with that pattern — no new database, no new file format, no new startup-ordering concern beyond "scan for one more filename pattern in the walk that already exists." It also degrades gracefully: an operator who deletes `.folder` by hand just means the folder reverts to normal derived-from-notes behavior (or disappears from the tree if also empty of notes), which is an acceptable, non-corrupting outcome.

**Alternatives considered:**

- _A `folders.json` (or similar) index file listing explicitly-created empty folders._ Rejected: introduces a second source of truth that can drift from the actual directory tree (the JSON could list a folder whose directory was deleted out-of-band, or vice versa), whereas a marker file _is_ the directory's content — it can't exist without the directory existing.
- _Track empty folders purely in memory, created on `POST /notes/tree` and never persisted._ Rejected: fails the explicit goal that a created folder survives a restart, which is the entire point of "creation" as opposed to a client-side-only UI affordance.

### `MetaIndex` gains a small separate set for marker-only folders, not a change to `NoteSummary`

**Decision:** `MetaIndex` (or `Storage`, wherever the startup scan already lives) adds a `Set<String>` of paths known to be marker-only folders. `notes/tree.dart`'s handler unions this set with the note-derived path-count map when building `folders`, defaulting `note_count` to `0` for a path that's in the set but not in the counts map.

**Why:** `NoteSummary` and the counts map it feeds are inherently note-shaped (one entry per note). A folder with zero notes has no note to attach a summary to, so it needs its own, much smaller piece of state rather than a synthetic zero-note `NoteSummary`.

**Alternatives considered:**

- _Synthesize a placeholder `NoteSummary` for the marker file itself._ Rejected: `NoteSummary` fields (`id`, `title`, `version`, timestamps) have no meaningful value for a marker file, and every other consumer of `MetaIndex.all` (search indexing, tag aggregation, list pagination) would need a special case to skip it — more special-casing than the small separate set.

### The marker is written only when the folder has no notes at creation time

**Decision:** `POST /notes/tree` writes `.folder` only if the target directory has zero note files in it at the moment of creation. If the folder already contains notes, the endpoint is a no-op that just reports the existing count — no marker is written, since the notes already make the folder durable.

**Why:** Keeps the on-disk footprint minimal (no marker files cluttering folders that don't need one) and avoids ever needing to reconcile "marker says empty, but notes exist" — that state is simply never created.

### `POST /notes/tree`, not a new `/folders` resource

**Decision:** Extend the existing `notes/tree.dart` route to also handle `POST`, rather than introducing `POST /folders` or similar.

**Why:** `GET /notes/tree` is already the one place the folder hierarchy is read from; `POST` to the same path reads naturally as "add to this tree" and needs no new route file, no new auth wiring, and no new capability boundary. It also reinforces that folders are not a first-class resource with their own CRUD surface (per proposal.md's non-goals — no rename, no delete) — this is a narrow, single-purpose addition to an existing endpoint, not the start of a `/folders` resource family.

**Alternatives considered:**

- _`POST /folders`._ Rejected: implies a first-class resource with an expected full CRUD surface (list/get/rename/delete), which this proposal deliberately does not provide.

## Risks / Trade-offs

- **[Risk]** An operator's backup/sync tool (e.g. a `.gitignore`-style dotfile filter, or a cloud-sync client that hides dotfiles) could silently drop `.folder` markers, making an empty folder "disappear" after a restore. → **Mitigation:** this is a cosmetic loss (the folder simply stops being listed until a note is added to it, or it's recreated), not a data-loss risk — no note content depends on the marker. Document the filename in `STORAGE.md` alongside the existing `<id>.md` convention so operators know not to filter it.
- **[Risk]** Two concurrent `POST /notes/tree` calls for the same new path could both see "doesn't exist" and both attempt `Directory.create` + marker write. → **Mitigation:** `Directory.create(recursive: true)` is idempotent (no error if it already exists), and writing the marker file is a plain overwrite of an always-empty file, so a race here produces the same end state either way — no `path_conflict`-style locking is needed, unlike note title/path collisions where two _different_ notes could conflict.

## Migration Plan

No migration needed: this is a purely additive capability. Vaults with no `.folder` markers behave exactly as today (all folders derived from notes). No changes to existing note files, frontmatter, or the search/link/tag indices.
