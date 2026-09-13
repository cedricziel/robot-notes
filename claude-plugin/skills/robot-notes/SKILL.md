---
name: robot-notes
description: This skill should be used when the user asks to "search notes", "create a note", "append to a note", "update a note", "move a note", "delete a note", "list notes", "find backlinks", or "create a folder" in robot-notes, or calls its MCP tools (list_notes, get_note, search_notes, create_note, update_note, append_to_note, delete_note, move_note, get_backlinks, create_folder). Also covers deciding whether to reuse an existing note instead of creating a duplicate, resolving a version_conflict or locked tool error, and working with robot-notes note ids and folder paths.
version: 0.1.0
---

# Working with robot-notes

robot-notes exposes a shared note workspace as a fixed catalog of ten MCP
tools. Notes are shared memory between humans and agents in this
workspace — treat them as a durable, multi-actor resource, not a private
scratchpad, and follow the workflow discipline below to avoid duplicating
or corrupting other actors' work.

## Core workflow rules

1. **Search before creating.** Always call `search_notes` (full-text,
   ranked) before `create_note`. A note that duplicates an existing one
   fragments the workspace's memory across two places nobody will think to
   check both of. If `search_notes` turns up a close match, extend that
   note instead of creating a new one.
2. **Append instead of read-modify-write.** To add material to the end of
   an existing note, call `append_to_note` directly rather than
   `get_note` followed by `update_note`. `append_to_note` is a safe
   server-side operation: it reads the current content, appends on a new
   line, and automatically retries if another actor wrote to the note
   first. Reach for `update_note` only when replacing the title, path, or
   existing content — not for adding to the end.
3. **Use `move_note` for relocation only.** `move_note` changes a note's
   folder without touching its title or content. Prefer it over
   `update_note` when the only change is `path`.
4. **Browse before guessing.** `list_notes` returns metadata only (id,
   title, path, version, timestamps — no content), paginated and
   filterable by `path` or `tag`. Use it to check whether a similarly
   titled note already exists, or to browse a folder, before deciding to
   create.
5. **Use `list_notes`, not `search_notes`, to enumerate everything.**
   `search_notes` is literal FTS5 keyword search, not a wildcard — there
   is no query that means "every note" (`*` is rejected as invalid FTS
   syntax, and a generic word like "notes" only matches notes that
   literally contain it, so an empty hit list does not mean the
   workspace is empty). To list all notes, call `list_notes` with no
   `query`-like argument and page through `next_cursor` until it is
   `null`.

## Tool catalog

| Tool             | Scope | Purpose                                                                                     |
| ---------------- | ----- | ------------------------------------------------------------------------------------------- |
| `list_notes`     | read  | Paginated metadata, filterable by `path`/`tag`, sortable oldest-id-first or `updated_desc`. |
| `get_note`       | read  | Full content of one note by `id`, plus lock holder if checked out.                          |
| `search_notes`   | read  | Full-text search over title + content, ranked, with snippets.                               |
| `create_note`    | write | Create a note (`title` required, `content`/`path` optional).                                |
| `update_note`    | write | Replace title/content/path; requires `version` (optimistic concurrency).                    |
| `append_to_note` | write | Append text to a note's end; retries automatically on write races.                          |
| `delete_note`    | write | Permanently delete a note by `id`. No undo.                                                 |
| `move_note`      | write | Change a note's folder; requires `version`.                                                 |
| `get_backlinks`  | read  | List every note linking to a given note, with context snippets.                             |
| `create_folder`  | write | Create an empty folder (and missing parents); idempotent no-op if it exists.                |

`list_notes`, `get_note`, `search_notes`, and `get_backlinks` need only the
`notes:read` scope; the other six need `notes:write`. A caller lacking the
required scope gets back a tool error rather than an exception — check for
`insufficient_scope` rather than assuming a call always succeeds.

## Note ids

Ids are ULIDs (26-character, case-insensitive Crockford base32) and are
opaque — always obtained from a prior `create_note`, `list_notes`,
`get_note`, or `search_notes` response. Never construct or guess an id: a
malformed id is rejected the same way a missing note is (`not_found`),
so there is no way to distinguish "bad id" from "id doesn't exist" from
the outside, and there is no reason to try.

## Optimistic concurrency (`version`)

`update_note` and `move_note` both require the note's current `version`
and fail with `version_conflict` if it has changed since it was last
read. On `version_conflict`, the error details carry `current_version`
and, if the caller holds `notes:read`, `current_content` — the note as
it now stands, written by whoever won the race. Do not resend the
original content with only the version bumped: that silently discards
the other actor's change. Instead, merge the intended edit into
`current_content` (re-reading with `get_note` first if the error
didn't include it) and resubmit that merged content with
`current_version`. `append_to_note` does this retry loop internally —
appending onto the latest content on each attempt — so it never
surfaces `version_conflict` to the caller under normal contention.

## Editor locks

A note can be checked out for editing by another actor. `get_note`
reports the current holder (`lock.holder`, `lock.expires_at`) when one
exists. A write to a locked note held by someone else fails with
`locked` and the holder's name in the error details — do not attempt to
force the write through; wait for the lock to expire or ask the holder.

## Folders and paths

`path` is a plain folder-like string (e.g. `projects/robot-notes`).
Creating or moving a note into a path already occupied by an
incompatibly-typed entry fails with `path_conflict`. `create_folder` is
idempotent: calling it on a path that already has content just returns
that path's current note count — there is no way to tell from the
response alone whether the folder was just created or already existed,
so do not depend on that distinction.

## Additional resources

- **`references/errors.md`** — full error-code reference (`not_found`,
  `version_conflict`, `locked`, `path_conflict`, `insufficient_scope`,
  and the rest) and how each tool call surfaces them.
- **`references/connecting.md`** — how the underlying HTTP/MCP endpoint
  authenticates (OAuth vs. static bearer key + `X-Actor`), for anyone
  setting up a _new_ MCP client connection to robot-notes rather than
  using one that is already configured.
