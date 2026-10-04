---
name: robot-notes
description: This skill should be used when working with the robot_notes memory provider or robot-notes MCP tools (robotnotes_search, robotnotes_list, robotnotes_note, robotnotes_remember, robotnotes_append, robotnotes_forget) — deciding whether to search or list, whether to append or create a new note, where session summaries and the memory mirror live, or how to react to a robotnotes tool error such as not_found, version_conflict, locked, or path_conflict.
version: 0.2.0
---

# Working with robot-notes (via the robot_notes memory provider)

This provider connects Hermes to a shared [robot-notes](https://github.com/cedricziel/robot-notes)
workspace: notes are shared memory between humans and agents in this
workspace, not a private scratchpad for one session. The native tools below are registered when `native_tools` is true. With
`native_tools: false`, use separately configured robot-notes MCP tools instead.
Treat the workspace as
a durable, multi-actor resource and follow the discipline below to avoid
duplicating or corrupting other actors' work.

## Vault boundary

The provider's configured `vault_id` selects one vault (`default` when omitted).
All tools, recall, session transcripts, and memory mirrors use that vault. Note
IDs and folders from another vault are not interchangeable. A vault access error
requires configuration or authorization to be corrected; do not retry against the
default vault. Vault selection does not itself restrict a static API key's access.

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

## MCP operations and databases

Use the schemas actually available in the session. Hermes prefixes server tools
as `mcp_<server_name>_<tool_name>`; the server name is configurable. Do not invent
native database tools or assume MCP was connected merely because recall works.

| Native name | MCP server operation |
| --- | --- |
| `robotnotes_search` | `search_notes` |
| `robotnotes_list` | `list_notes` |
| `robotnotes_note` | `get_note` |
| `robotnotes_remember` | `create_note` |
| `robotnotes_append` | `append_to_note` |
| `robotnotes_forget` | `delete_note` |

The same search-before-create, append, pagination, and deletion discipline
applies to MCP operations. Ownership guidance is a workflow rule; deletion is
not automatically restricted to notes created by this actor.

1. Discover with `list_databases`, then read `get_database` before querying or
   changing rows. Use `query_database` with a saved view or explicit filter,
   sort, grouping, and opaque pagination cursor.
2. Always supply a source to `create_database`, even though the server permits
   omission. Choose exactly one folder or nonblank tag. `folder: ""` selects
   the vault root; `include_subfolders: true` makes that the whole vault.
   Definition note location is separate from the source of rows.
3. Use `create_row` to validate properties and establish source membership.
   Folder rows default to the source folder; tag rows receive the source tag.
   Use schema-declared keys and values: actual numbers/booleans, ISO dates,
   declared select options, lists for multi-select, and server-supported
   relation values. Read the tool's encoding guidance for exact formats.
4. Use `update_properties` to set/unset individual keys without rewriting the
   body or supplying a version. A key cannot be both set and unset. The server
   validates against covering databases and ignores editor locks for patches.
5. `update_database` requires the latest version. Each supplied source,
   properties, or views section replaces that whole section; omitted sections
   survive. Fetch and reconcile on version conflict rather than blindly retry.
   Removing a schema property does not erase stored values from rows.
6. Rows and definitions are notes: `get_note` reads them, `update_note` edits
   title/body, `move_note` changes location, and `delete_note` deletes them.
   Moving a note may change database membership. Deleting a definition does not
   delete its rows. Never interpret deletion as an archive action.
7. The provider's primary-context write rule does not enforce permissions on
   MCP calls. Follow task authorization and the configured MCP grant/tool
   visibility. `native_tools: false` only hides native tools; lifecycle hooks
   can still write in primary contexts.
