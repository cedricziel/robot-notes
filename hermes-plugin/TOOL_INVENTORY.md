# Hermes robot-notes tool inventory

Analysis as of 2026-10-04. This inventory distinguishes existing capabilities from proposed native wrappers.

## Recommendation

Keep the native plugin for Hermes memory lifecycle integration. Use the existing
robot-notes MCP endpoint for general note/database operations by default. Add
native database tools only if a single provider configuration, consistent
Hermes-context write gating, and curated schemas justify maintaining a second
adapter. Do not expose duplicate native and MCP versions of the same operation
in one session by default.

The server currently registers 19 MCP tools; the Hermes provider exposes six
native note tools. Seven database tools and six other tools are missing for
literal MCP parity. There are also REST-only workspace capabilities.

## Existing tools: retain and extend

| Hermes tool | MCP counterpart | Proposed changes |
| --- | --- | --- |
| `robotnotes_search` | `search_notes` | Add `tag`; retain query/path/limit; describe server-configured hybrid search accurately. |
| `robotnotes_list` | `list_notes` | Add `tag`, `title`, and `sort` (`id`, `updated_desc`); preserve cursor pagination. |
| `robotnotes_note` | `get_note` | Already returns the raw note response, including properties/type when supplied by the server; document that it can read rows and definitions. |
| `robotnotes_remember` | `create_note` | Add optional `properties`; teach agents to use create-row for database membership and schema validation. Keep search-before-create guidance. |
| `robotnotes_append` | `append_to_note` | Retain atomic append and the old-server fallback; test property preservation. |
| `robotnotes_forget` | `delete_note` | Document that rows/definitions are notes. Current tool wording says “this agent created,” but the handler does not enforce ownership. Do not claim an ownership restriction that does not exist. |

## Seven database tools

Names deliberately mirror the server's MCP verbs after the `robotnotes_` prefix.
This supersedes the earlier conversational shorthand `robotnotes_databases` and
`robotnotes_database`.

| Proposed native tool | Inputs (`?` means optional) | Server route / MCP tool | Behavior and requirements |
| --- | --- | --- | --- |
| `robotnotes_list_databases` | none | `GET /databases` / `list_databases` | Return id, title, definition location, source, row count. Do not silently scope listing to an agent folder. Any convenience folder filter would be a new adapter feature, clearly distinguished from row-source filtering. |
| `robotnotes_get_database` | `id` | `GET /databases/{id}` / `get_database` | Return version, source, property definitions, views, timestamps. Read before creating rows or editing properties/schema. |
| `robotnotes_query_database` | `id`, `view?`, `filter?`, `sort?`, `group_by?`, `limit?`, `after?` | `POST /databases/{id}/query` / `query_database` | Return rows, next cursor, and groups where applicable. Expose nested filter objects and typed sort entries. Request overrides replace corresponding saved-view fields. Page limit 1–200. Keep cursors opaque. |
| `robotnotes_create_row` | `id`, `title`, `properties?`, `content?`, `path?` | `POST /databases/{id}/rows` / `create_row` | Validate against schema; folder-source path defaults to source folder and must be covered; tag-source rows receive the source tag automatically. Returns the created note/row. |
| `robotnotes_update_properties` | note `id`, `set?`, `unset?` | `PATCH /notes/{id}/properties` / `update_properties` | Patch selected keys without rewriting body; at least one change, no overlapping set/unset keys. No version required; server serializes patches and ignores editor locks. Validation uses covering databases. |
| `robotnotes_create_database` | `title`, **`source`**, `path?`, `properties?`, `views?`, `content?` | `POST /databases` / `create_database` | Make source required in the native schema even though server/MCP still allow omission. Exactly one folder or nonblank tag; root is explicitly `folder: ""`; make include-subfolders explicit in guidance. Definition location and row source are different concepts. |
| `robotnotes_update_database` | `id`, `version`, `source?`, `properties?`, `views?` | `PUT /databases/{id}` / `update_database` | Send If-Match. Each supplied section replaces that whole section; omitted sections survive. Never retry a conflict blindly. Removing a schema property leaves stored row values intact. Title/path/body are edited using ordinary note operations. |

Property schemas cover text, URL, number, checkbox, date, select, multi-select,
and relation. Publish encoding guidance: actual booleans/numbers, ISO dates,
option strings/lists, and the server's relation encoding. Validate source and
schema shapes locally for useful errors; retain server-side validation as the
authority. Do not flatten the query filter grammar into an ambiguous string.

### No extra CRUD aliases needed

- Get a row: `robotnotes_note`.
- Edit a row title/body: proposed `robotnotes_update_note`.
- Move a row: proposed `robotnotes_move_note`; moving can change membership.
- Delete a row or database definition: `robotnotes_forget`. Deleting a definition
  does not imply cascading deletion of its rows.
- Add/edit/delete/reorder properties or views: `robotnotes_update_database` with
  the complete replacement section, after fetching the latest definition.
- Read row properties: `robotnotes_note` or `robotnotes_query_database`.

Separate tools for each property type, board move, view CRUD, rename-database,
and delete-database would mostly duplicate these operations.

## Six other additions for literal MCP parity

| Proposed native tool | Inputs | Current server support |
| --- | --- | --- |
| `robotnotes_update_note` | `id`, `version`, `title?`, `content?`, `path?`, `properties?` | `PUT /notes/{id}` / `update_note`. Requires If-Match; respect lock and version errors. Prefer patch-properties for partial property edits. |
| `robotnotes_move_note` | `id`, `version`, `path` | `PUT /notes/{id}` / `move_note`. Preserve title/body; moving can enter or leave databases. |
| `robotnotes_get_backlinks` | `id` | `GET /notes/{id}/backlinks` / `get_backlinks`. Discover referencing notes. |
| `robotnotes_create_folder` | `path` | `POST /notes/tree` / `create_folder`. Idempotent; creates parents. |
| `robotnotes_request_upload` | `path`, `filename`, `size_bytes?` | MCP `request_upload` only for reservation. Returns token, upload URL, expiry. A REST-only native adapter cannot reserve through an equivalent REST endpoint today. |
| `robotnotes_finalize_upload` | `token` | MCP `finalize_upload` only for finalization. Caller uploads bytes via `PUT /notes/file-uploads/{token}` between these two tools. |

For a native plugin, prefer **one `robotnotes_upload_file`** accepting an
explicit local file path and vault destination, streaming through authenticated
`POST /notes/files` multipart. This replaces the two-phase MCP pair for native
use, making 12 additions rather than 13. Local file access must follow the host's
file-access rules; do not inline binary/base64 payloads into model tool arguments.
The current provider runs where Hermes runs, so a local path refers to that host,
not automatically to an attached user's device.

## Optional REST-only tools

These expand beyond the current MCP catalog and are secondary to databases.

| Proposed tool | Inputs | Route | Purpose |
| --- | --- | --- | --- |
| `robotnotes_list_folders` | none | `GET /notes/tree` | Discover folder structure and direct note/file counts. |
| `robotnotes_list_tags` | none | `GET /tags` | Discover tags and counts before choosing a tag source. |
| `robotnotes_get_links` | `id` | `GET /notes/{id}/links` | Inspect outgoing links and resolution state. |
| `robotnotes_list_files` | `path?` | `GET /notes/files` | Inspect files in a folder. |
| `robotnotes_download_file` | vault file path, local destination | `GET /notes/files/{path}` | Stream a file to host storage; return metadata/path rather than raw bytes. |
| `robotnotes_acquire_lock` | `id` | `POST /notes/{id}/lock` | Acquire/refresh an editor lease for a deliberate editing session. |
| `robotnotes_refresh_lock` | `id` | `PUT /notes/{id}/lock` | Extend an existing lease. |
| `robotnotes_release_lock` | `id` | `DELETE /notes/{id}/lock` | Release a held lease. |

Prefer client-managed leases over three model-visible lock tools unless an
actual workflow requires explicit locking. The useful workflow with existing
version checks does not automatically require lease management.

Do not add invite management, OAuth registration/revocation, telemetry config,
or health checks as routine knowledge-management tools. They are operator,
transport, or client-internal concerns. WebSocket subscriptions are an internal
cache/refresh mechanism rather than another one-shot tool.

## Native plugin versus MCP

| Dimension | Current native plugin | robot-notes MCP |
| --- | --- | --- |
| Explicit database work | Not implemented | All seven database operations already implemented |
| Automatic recall | Provider prefetch/queue-prefetch injects context | Tool calls alone do not implement memory-provider hooks |
| Session archive | Provider writes a bounded session transcript | Requires an additional lifecycle integration |
| Built-in memory mirror | Provider mirrors memory/user-note edits | Requires an additional lifecycle integration |
| Hermes context rules | Explicit writes currently disabled in subagent/cron/flush contexts | Server enforces credential scopes; does not know Hermes agent_context by itself |
| Configuration/auth | Provider config + environment secret; static bearer key and actor header | Hermes HTTP MCP configuration; static headers or supported OAuth flow; server has read/write scopes |
| Reuse | Hermes-specific Python adapter | Same tools work in other MCP clients |
| Tool contract maintenance | Adding wrappers duplicates schemas, parameters, docs, and tests | Server publishes its tool catalog centrally |
| Local files | Native code can stream a selected host file through REST | Two-phase upload tools plus an HTTP byte-transfer step |

MCP is also carried over HTTP here. Direct REST does not remove the remote
server, network round trip, or server validation. Do not claim a meaningful
latency/token saving without measurement; duplicate catalogs can instead add
schema noise. Static bearer auth is supported by both paths, so avoiding OAuth
is not an exclusive native-plugin advantage.

The native write gate is adapter policy, not server-enforced authorization.
Enabling writable MCP tools alongside a read-only native context can bypass that
policy; compose credentials and tool visibility deliberately. Conversely, the
current native policy also prevents explicit cron/subagent database writes, so
it is unsuitable for writable scheduled workflows unless that policy is changed.

Only one external Hermes memory provider can be active. Using robot-notes purely
as MCP tools leaves that provider slot available for another backend. Native
lifecycle integration can coexist with MCP operations using `native_tools: false`
in `robot_notes.json`; the six native schemas are hidden and direct dispatch is
rejected while the lifecycle hooks remain active.

## Delivery options and order

1. **Lowest duplication:** retain the provider lifecycle, add an option to hide
   its explicit tool catalog, and document connecting robot-notes MCP. Bundle or
   configure the same behavioral skill for MCP names. Filter MCP tools as needed.
2. **Native-first experience:** add the seven database tools, the four missing
   note/folder operations, upload-file, and extend existing list/search/create
   schemas. This is 12 new tools plus extensions, for 18 native tools total.
3. Add REST-only folder/tag/link/file reads where needed. Add lease tools only
   after demonstrating a workflow that benefits from them.

If native database tools are chosen, ship discovery/query/row/property tools
first, then schema-management tools. All new writes must enter the write-tool
registry, errors must preserve validation details, and skill/prompt/README must
agree with the actual schemas. Do not automatically retry non-idempotent creates
or stale schema replacements.

Validation should cover source scope (including root-only), property preservation,
relations/options/dates, view overrides, pagination/group counts, If-Match
conflicts, set/unset semantics, write-context gates, and transport error mapping.
Use unit tests, a real-server e2e suite, and the pinned Hermes contract suite.
Cross-adapter tests should check observable server behavior so REST and MCP
wrappers do not drift.

## Evidence

Repository sources inspected: `robot_notes/tools.py`, `client.py`, `__init__.py`,
`README.md`; `server/lib/src/mcp/tools.dart`; database, note, folder, tag, lock,
and file routes; shared database DTOs.

Hermes host behavior checked against its official documentation:

- [Memory Provider Plugins](https://hermes-agent.nousresearch.com/docs/developer-guide/memory-provider-plugin/): lifecycle hooks, context, and single-provider rule.
- [MCP integration](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp/): HTTP headers, OAuth, tool naming, and filtering.

The companion implementation adds the native-tools switch and MCP guidance.
The proposed additional native wrappers and REST-only tools remain unimplemented.
