---
name: robot-notes
description: This skill should be used when working with the robot_notes memory provider's tools (robotnotes_search, robotnotes_list, robotnotes_note, robotnotes_remember, robotnotes_append, robotnotes_forget) — deciding whether to search or list, whether to append or create a new note, where session summaries and the memory mirror live, or how to react to a robotnotes tool error such as not_found, version_conflict, locked, or path_conflict.
version: 0.1.0
---

# Working with robot-notes (via the robot_notes memory provider)

This provider connects Hermes to a shared [robot-notes](https://github.com/cedricziel/robot-notes)
workspace: notes are shared memory between humans and agents in this
workspace, not a private scratchpad for one session. The tools below are the
`robotnotes_*` explicit tools this provider registers; treat the workspace as
a durable, multi-actor resource and follow the discipline below to avoid
duplicating or corrupting other actors' work.

## Where things live

- Session transcripts are filed one note per session under
  `conversations/<actor>/<session id>` and updated (not duplicated) for a
  resumed session.
- `Hermes/Memory` and `Hermes/User` mirror this agent's built-in
  `MEMORY.md`/`USER.md` one-directionally. Once mirrored, the workspace copy
  is the shared, authoritative one — other actors may read or extend it.

## Core workflow rules

1. **Search before creating.** Always call `robotnotes_search` before
   `robotnotes_remember`. A note that duplicates an existing one fragments
   the workspace's memory across two places nobody will think to check both
   of. If `robotnotes_search` turns up a close match, extend that note
   instead of creating a new one.
2. **Append instead of re-creating.** To add material to the end of a note
   found via search, use `robotnotes_append(id, content)` rather than
   creating a second note or fetching and re-remembering the whole thing.
   `robotnotes_append` is a safe server-side operation: it retries
   automatically if another actor wrote to the note first.
3. **List, don't search, to enumerate everything.** `robotnotes_search` is
   keyword full-text search, not a wildcard — there is no query that means
   "every note" (a query like `*` is rejected, and a generic term like
   "notes" only matches notes that literally contain it, so an empty hit
   list does not mean the workspace is empty). Use `robotnotes_list` to
   browse a folder or page through the whole workspace instead.
4. **Fetch by id with `robotnotes_note`**, not by guessing — ids only ever
   come from a prior `robotnotes_search`, `robotnotes_list`, or
   `robotnotes_remember` result.
5. **`robotnotes_forget` has no undo.** Only delete a note this agent
   created, and only when the task genuinely calls for it.

## Tool catalog

| Tool                  | Purpose                                                                          |
| ---------------------- | --------------------------------------------------------------------------------- |
| `robotnotes_search`    | Keyword full-text search over the shared workspace.                              |
| `robotnotes_list`      | Paginated metadata for every note (id, title, path, version) — use to enumerate. |
| `robotnotes_note`      | Fetch one note's full content by id.                                             |
| `robotnotes_remember`  | Create a new note when search turns up nothing to extend.                       |
| `robotnotes_append`    | Append content to an existing note's end; retries on write races.               |
| `robotnotes_forget`    | Permanently delete a note by id. No undo.                                       |

## Errors

A robotnotes tool call that fails returns a tool error rather than raising —
check the `error` field of the JSON result. See the server's full
error-code reference rather than duplicating it here:
https://github.com/cedricziel/robot-notes/blob/main/server/API.md#error-envelope
