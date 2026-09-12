## Context

See proposal.md - Why. Today's storage layer is the only thing that changes shape structurally; every client (REST, MCP, Flutter, realtime) already addresses notes by `id`, never by file path, so `notes-storage` can be rewritten underneath them. The specs (see `specs/*/spec.md` in this change) define the observable contract; this document covers the approach that makes it hold together as one system.

`GET /notes` already supports `sort` (`id` | `updated_desc`) and an `after` cursor as of the current `notes-api` baseline — this change's `path`/`tag` filters are additive and compose with either sort order; they do not replace it.

## Goals / Non-Goals

**Goals:**

- Real, hand-editable vault layout (`<folder>/<Title>.md`) with stable `id`-based API addressing underneath it
- Obsidian-portable link syntax (`[[Title]]`) with rename-propagation and phantom-link support
- One merged tag model across frontmatter and inline `#tag`
- A migration path from the current flat `<id>.md` layout with zero manual intervention

**Non-Goals:**

- Heading-anchor links (`[[Title#Heading]]`)
- A general-purpose graph query language (backlinks/links endpoints are the only graph surface)
- Solving duplicate-title ambiguity beyond "first by id order, logged"
- Changing auth, locking mechanics, or the WS transport itself

## Decisions

**1. `id` stays the API address; the filename becomes derived state.**
`GET/PUT/DELETE /notes/{id}` never change. `path` and `title` become inputs that the storage layer projects onto a filename. This is what lets every other capability (search, mcp-server, flutter-client, realtime-sync) stay untouched at the protocol level and only gain new optional fields/params, rather than needing a migration of their own addressing scheme.
Alternative considered: address notes by path instead of id (more literally "files are the identity", closer to how a bare filesystem works). Rejected — it would break `lock-management`'s per-id lock table and every existing client integration for no behavioral gain, since nothing needs path-based addressing.

**2. Links are stored as plain `[[Title]]` text; resolution is a derived index, not part of the file format.**
This is what keeps the vault Obsidian-portable — a user can literally point Obsidian at `<data-dir>/content/` and it will parse the same links. The cost is that resolution is title-based and therefore ambiguous when titles collide, and renaming has to actively rewrite other files' text (there is no stable id hiding inside the link). This mirrors how Obsidian itself works, so it isn't a new class of fragility — it's the same trade every Obsidian vault already makes.
Alternative considered: embed the id in the link (e.g. `[[Title]](id:01J...)`), resolved without rewriting on rename. Rejected — it breaks plain-text/Obsidian portability, which was the explicit goal, in exchange for avoiding a rewrite step that's already required to be lock-aware and idempotent for other reasons.

**3. Rename-propagation is implemented as ordinary writes to the referencing notes, not a special-cased bulk operation.**
Each rewrite goes through the same version-increment, lock-check, and `changed`-broadcast path as a normal `PUT`. This means lock semantics, optimistic concurrency, and realtime updates for the propagation writes come for free from existing machinery instead of needing a parallel code path — the only new logic is "find referencing notes" (via the link-edges table) and "skip if locked" (see `lock-management` delta).

**4. The link-edges table and tag set live in `search.db`, not in note frontmatter.**
Both are fully derivable from note content on a rebuild, same as the existing FTS index. Keeping them out of frontmatter avoids a second source of truth that could drift, and reuses the existing "index is a rebuildable cache" invariant (`search` capability) instead of inventing a new persistence guarantee.

**5. Path/title sanitization and collision handling reuse the existing error-shape convention.**
`path_conflict` returns the same `{"error": "..."}` shape as today's `version_conflict`/`locked`, so no client needs a new error-handling pattern — just a new code to recognize.

**6. Path-collision checks are case-insensitive, NFC-normalized, and made atomic against concurrent writes.**
The primary Flutter targets include macOS (default case-insensitive APFS) and Windows, both of which treat `Ideas.md` and `ideas.md` as the same file regardless of what the in-memory index thinks; and APFS itself may normalize filenames to NFD on write even when the client sent NFC. Comparing paths case-sensitively and without normalization would let two different notes silently alias to one file. So collision detection normalizes to NFC and compares case-insensitively, and — since a naive "check the index, then write" is a check-then-act race between two concurrent operations targeting the same resolved path — the actual create/rename/move is serialized per target path (a lock keyed by the lowercased, NFC target path, or an OS-level exclusive-create primitive), not just per source note id as `notes-storage`'s existing per-note serialization already does.
Alternative considered: leave comparison case-sensitive and exact-Unicode, matching the letter of "just compare strings." Rejected once traced through to the actual deployment targets — it would work on Linux servers but silently corrupt data the first time two similarly-titled notes are renamed concurrently on the primary desktop target.

## Risks / Trade-offs

- **[Risk] Rename-propagation is a multi-file write triggered by a single API call** → could surprise a caller who only intended to rename one note. Mitigation: it's the same behavior Obsidian itself has trained users to expect from wikilink-based vaults; documented in the `links` spec; each propagated write is a normal version-incrementing save, fully visible via `changed` events and normal version history semantics (nothing silent).
- **[Risk] Duplicate titles make link resolution ambiguous, and multiple notes/writes can contend for the same filename** → could silently resolve to the "wrong" note, or (worse) let one write clobber another's file. This is one family of risk with two manifestations: read-time (link resolution) and write-time (rename/move/migration). Mitigation: link resolution gets a deterministic tie-break (first by id order) plus a logged warning, explicitly scoped as a v1 limitation; write-time contention is closed for real (not just documented) via decision 6's per-target-path atomicity and the migration's full-namespace de-dup check (see `notes-storage`'s migration requirement) — the "logged and move on" treatment is reserved for the read-time ambiguity case only, never for a write that could destroy data.
- **[Risk] Migration runs on every startup until all legacy files are converted** → repeated directory scans on large vaults. Mitigation: migration only acts on files matching `<ulid>.md` with no `path` key, so once migrated the check is a cheap no-op scan; can be measured and revisited if it shows up in startup-time metrics.
- **[Risk] Filesystem path length/character limits vary by OS** → a very long nested folder+title could fail to write on some platforms. Mitigation: sanitization strips illegal characters; out of scope for this change to add path-length truncation, but the existing "colliding path" 409 pattern extends naturally to a future "path too long" error if it comes up.

## Migration Plan

1. Ship the storage-layer change (Phase 1 in tasks.md) behind the existing atomic tmp+fsync+rename write path — no schema flag needed, since migration is self-describing (presence/absence of `path` in frontmatter).
2. On first startup after upgrade, the migration in `notes-storage` runs automatically, renaming legacy `<id>.md` files to `<Title>.md` at vault root and logging what it did.
3. `search.db` is treated as a rebuildable cache; the schema version bump (adding path/tags/link-edges columns) causes the existing "schema mismatch" rebuild path to fire automatically on first startup — no separate search migration step.
4. Rollback: since `id` never changes and frontmatter is additive (`path` is a new key, old `tags` behavior is unaffected), downgrading to a pre-change server binary would only fail on the renamed-filename assumption in the old `notes-storage` code — operators rolling back should restore the pre-migration data directory from backup rather than rely on forward-compatibility.
