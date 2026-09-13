# robot-notes MCP error reference

Every tool call returns a normal JSON-RPC success result; a failed
operation is reported as `isError: true` with a `code` field from this
list, not as a JSON-RPC error — a JSON-RPC error means the request
itself was malformed (unknown tool name, schema violation), not that the
operation was refused.

| Code                 | Meaning                                                                                                                                                          | Seen from                                                                                                  |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `not_found`          | The note id does not exist, or was not a well-formed ULID.                                                                                                       | `get_note`, `update_note`, `append_to_note`, `delete_note`, `move_note`, `get_backlinks`                   |
| `version_conflict`   | The supplied `version` no longer matches the note's current version. Details include `current_version` and, if the caller holds `notes:read`, `current_content`. | `update_note`, `move_note` (and internally retried by `append_to_note`)                                    |
| `locked`             | Another actor currently holds the note's editor lock. Details include `holder`.                                                                                  | `update_note`, `append_to_note`, `delete_note`, `move_note`                                                |
| `path_conflict`      | The target `path` collides with an existing, incompatible entry.                                                                                                 | `create_note`, `update_note`, `move_note`                                                                  |
| `insufficient_scope` | The caller's token lacks the scope the tool requires (`notes:read` or `notes:write`).                                                                            | any tool                                                                                                   |
| `validation_failed`  | A supplied argument failed a semantic check the JSON Schema can't express (blank title, blank search query, unsupported `sort` value, empty `path`).             | `list_notes`, `search_notes`, `create_note`, `update_note`, `append_to_note`, `move_note`, `create_folder` |

Contrast `validation_failed` (semantically invalid input, reported as a
normal tool result) with a JSON-RPC `-32602 Invalid params` error (the
request didn't match the tool's declared JSON Schema at all — wrong
type, missing required key) and `-32602`-via-`McpUnknownToolException`
(no such tool name). Both of those never reach tool-level error
handling; they are rejected before the handler runs.

## Retry guidance

- `version_conflict`: re-read the fresh `current_version` from the error
  details (no extra `get_note` call needed) and reissue the write with
  it. Do not retry blindly with the stale version.
- `locked`: not retryable on a timer — either wait for the holder to
  release the lock (or for it to expire, per `expires_at` from
  `get_note`) or surface the conflict to the user instead of looping.
- `insufficient_scope`: not retryable — the caller's token needs a
  different grant. Do not attempt the same call again with the same
  credentials.
