# robot-notes Memory Provider

Uses a [robot-notes](https://github.com/cedricziel/robot-notes) workspace as
Hermes Agent's external memory: notes as shared memory between humans and
agents. Talks to robot-notes' existing bearer-key REST API directly — no MCP
client, no separate database.

## Requirements

- A running robot-notes server and its static API key (see the main repo's
  `README.md` — `ROBOT_NOTES_API_KEY` / `--api-key`)
- `pip install httpx`

## Install

Hermes discovers memory providers from four sources ([developer guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/memory-provider-plugin.md#installation-layouts)); this plugin supports the three that apply outside the bundled-with-Hermes case. Pick one:

### User plugin directory (symlink or copy)

Copy or symlink `hermes-plugin/robot_notes/` into `$HERMES_HOME/plugins/robot_notes/`:

```bash
ln -s "$(pwd)/hermes-plugin/robot_notes" "$HERMES_HOME/plugins/robot_notes"
```

### `hermes plugins install` (same layout, fetched for you)

`hermes plugins install` accepts a Git identifier with a subdirectory, and this
repo's `plugin.yaml` lives in `hermes-plugin/robot_notes/`, not the repo root —
name that subdirectory explicitly:

```bash
hermes plugins install cedricziel/robot-notes/hermes-plugin/robot_notes
```

This clones the repo and installs the `hermes-plugin/robot_notes/` subtree into
`$HERMES_HOME/plugins/robot_notes/`, same as the symlink above. Plain
`hermes plugins install cedricziel/robot-notes` (no subdirectory) will **not**
work — it looks for `plugin.yaml` at the repository root, and this repo keeps
several components (`server/`, `app/`, `claude-plugin/`, `hermes-plugin/`) side
by side.

### `pip install` (packaged provider, entry point)

No copy under `$HERMES_HOME/plugins/` is needed; Hermes discovers the provider
through a `hermes_agent.memory_providers` entry point once the package is
installed into the same Python environment Hermes runs in:

```bash
pip install "git+https://github.com/cedricziel/robot-notes@main#subdirectory=hermes-plugin"
```

`pip`'s `#subdirectory=` fragment builds only `hermes-plugin/` from the
monorepo checkout, using its own `pyproject.toml`
(`[project.entry-points."hermes_agent.memory_providers"] robot_notes =
"robot_notes:register"`). Verify the entry point landed in the environment
Hermes uses:

```bash
python -c 'import importlib.metadata as m; print([e.name for e in m.entry_points(group="hermes_agent.memory_providers")])'
# -> ['robot_notes']
```

A package entry point still gets `config_schema.py`/`cli.py` support and the
setup wizard below — this plugin does not currently ship either file, so it is
equivalent to the directory installs for now.

### Project-local plugin (opt-in)

For a per-repo install, drop the same directory under `./.hermes/plugins/robot_notes/`
in the project and set `HERMES_ENABLE_PROJECT_PLUGINS=1`; Hermes discovers it
the same way as the user directory, just scoped to that working tree.

### Plugin catalog (planned)

A future release of this plugin will be submittable to the
[Hermes plugin catalog](https://github.com/NousResearch/hermes-agent/tree/main/plugin-catalog)
so it can be installed by name (`hermes plugins install robot_notes`) instead
of a Git URL/subdirectory. See [`../catalog/README.md`](../catalog/README.md)
for the draft entry and the submission checklist.

## Setup

```bash
hermes memory setup    # select "robot_notes"
```

Or manually:

```bash
hermes config set memory.provider robot_notes
echo "ROBOT_NOTES_API_KEY=rn_your_secret" >> ~/.hermes/.env
```

## Config

`hermes memory setup` prompts for `base_url`, the bearer credential, and an
optional `vault_id` (blank uses `default`). The optional `actor` setting is
configured directly in `robot_notes.json`.

| Key        | Where                                | Description                          |
| ---------- | ------------------------------------- | ------------------------------------ |
| `base_url` | `robot_notes.json`                    | robot-notes server base URL          |
| `vault_id` | `robot_notes.json`                    | Selected vault ID (default: `default`) |
| `api_key`  | `ROBOT_NOTES_API_KEY` (env, secret)   | Bearer credential for every request  |

## `robot_notes.json` reference

Non-secret config lives at `$HERMES_HOME/robot_notes.json` and never contains
the API key:

| Key        | Required | Default   | Description                                                        |
| ---------- | -------- | --------- | -------------------------------------------------------------------- |
| `base_url` | Yes      | —         | robot-notes server base URL, e.g. `https://notes.example.com`      |
| `native_tools` | No | `true` | Set to JSON `false` to keep automatic memory hooks while using MCP for explicit operations. Restart Hermes after changing it. |
| `upload_roots` | No | `[]` | JSON list of absolute directory paths that `robotnotes_upload_file` may read from. Empty disables uploads. Not prompted by setup, which preserves an existing value. Restart Hermes after changing it. See [File uploads](#file-uploads). |
| `vault_id` | No       | `default` | Stable vault ID, sent as `X-Vault-Id` on every request |
| `actor`    | No       | `hermes`  | Actor name attributed to this agent's writes (sent as `X-Actor`); also scopes the per-session summary note under `conversations/<actor>/` |

```json
{
  "base_url": "https://notes.example.com",
  "actor": "hermes",
  "vault_id": "default"
}
```

## Memory provider with MCP tools

For database work, keep this provider active for automatic recall, session
transcripts, and built-in memory mirroring, and connect the server's existing
MCP tools for explicit operations. No native database wrappers are needed.

Set `$HERMES_HOME/robot_notes.json` to:

```json
{
  "base_url": "https://notes.example.com",
  "actor": "hermes",
  "native_tools": false
}
```

Keep `ROBOT_NOTES_API_KEY` configured for the provider's REST lifecycle hooks.
`native_tools: false` hides every native schema, rejects direct native tool
calls with `tools_disabled`, and removes native tool instructions from its
prompt. It does not disable recall, transcripts, or mirroring, and it does not
connect MCP automatically. Setup preserves this setting and your actor.
The value must be a JSON boolean, not the string `"false"`.

Separately configure the server in Hermes' `config.yaml`, for example using OAuth:

```yaml
mcp_servers:
  robot_notes:
    url: "https://notes.example.com/mcp"
    auth: oauth
```

Use `hermes mcp login robot_notes` to authorize that connection. Static bearer
headers are also supported by Hermes: configure `Authorization: Bearer <key>`
and `X-Actor` using your installation's credential management. The provider's
API key is not automatically copied into MCP configuration. Never commit a real
key in a sample configuration. Restart Hermes after changing the provider
setting; MCP configuration can be refreshed with `/reload-mcp`.

Hermes exposes server tools as `mcp_<server_name>_<tool_name>`; with the name above,
`query_database` becomes `mcp_robot_notes_query_database`. Optional
`tools.include` lists use the unprefixed server names. For example, a read-only
catalog can include `list_notes`, `get_note`, `search_notes`, `get_backlinks`,
`list_databases`, `get_database`, and `query_database`.
See [Hermes MCP documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp/)
for authentication and filtering details.

The server already provides all seven database tools: `list_databases`,
`get_database`, `query_database`, `create_row`, `update_properties`,
`create_database`, and `update_database`. The bundled skill covers both native
and MCP names, source selection, typed properties, and version conflicts.
[The full inventory](../TOOL_INVENTORY.md) covers other supported operations and
possible native extensions.

The provider's subagent/cron/flush write gate applies only to its own hooks and
native tools. It does not constrain separately connected MCP tools. Use a
read-only OAuth grant and/or MCP tool filtering for read-only workflows; the
static bearer key grants full server access. Automatic provider writes remain
subject to their existing primary-context rule. Disabling native tools alone
does not make the provider read-only.

## Vault selection and authorization

All recall queries, explicit tools, session transcripts, and memory mirrors use
one configured vault. Use `GET /vaults` with your bearer credential to find its
stable ID, then set `vault_id` during setup or in `robot_notes.json`. Restart or
reinitialize the provider after changing it. Existing configurations continue to
use `default`; invalid or unauthorized vaults return errors rather than falling
back to another vault. Reinitialization clears recall caches and discards results
from searches queued against the previous vault.

`ROBOT_NOTES_API_KEY` can contain the server's static API key or a REST-resource
OAuth access token. For restricted access, authorize a token against the server
base URL with the selected vault and the required note read/write scopes. MCP
resource tokens are not accepted by REST. The static API key grants access to all
vaults; selecting `vault_id` only chooses the target. The plugin does not perform
OAuth sign-in or refresh expired access tokens automatically.

## Data sent to the server

Optional background extraction uses a separate source capture outbox. Set
`source_capture: true` and `source_scope_id` through Hermes setup, its memory
provider dashboard, or `robot_notes.json` after a human configures that scope on
the server. The primary conversation captures turn and
session observations; server scope settings select `completed_turn`, `session_end`,
or `both` for extraction. Capture and server extraction are disabled by default.
See [background extraction configuration](../../docs/background-knowledge-extraction.md)
for model settings, scope permissions, and proposal review.

Everything this plugin sends to robot-notes goes over the plain REST API
above (bearer credential + `X-Actor` and `X-Vault-Id` headers, no additional client). Nothing is sent
to any service other than the `base_url` configured above.

- **Recall queries** — `prefetch`/`queue_prefetch` send the query text for
  the current turn to `GET /search`. robot-notes returns matching note
  titles and snippets only; the response is injected as context, nothing is
  written back.
- **Session transcripts** — `on_session_end` sends the session's messages as
  the content of one summary note per session, under
  `conversations/<actor>/<session id>`. The readable transcript includes
  filtered user and assistant text, with a bounded body; tool results and
  non-text content are excluded. Treat the workspace as within the conversation's
  trust boundary.
- **Built-in memory mirror** — content written to Hermes' own
  `MEMORY.md`/`USER.md` is mirrored one-directionally by default into
  the configured memory notes, defaulting to `Hermes/Memory` and
  `Hermes/User` (see Write behavior below);
  whatever text lands in those files is sent to the server.
- **Explicit tool writes** — `robotnotes_remember` sends the model-authored
  `title`/`content` as a new note or institutional draft; `robotnotes_forget`
  removes an ordinary note or submits a curated deletion proposal. The server authorizes deletion using the configured credentials;
  the tool does not restrict deletion to notes created by this agent.
  `X-Actor` provides attribution, not ownership authorization. Deletion has
  retained history and evidence are separate, so use removal only when the task calls for it. `robotnotes_note`/`robotnotes_list` are read-only and only fetch
  data, they send no new content.
- **File uploads** — `robotnotes_upload_file` streams the named local file to
  `POST /notes/files`. File contents leave the host only on this explicit call,
  and only for files under `upload_roots`.

Recall (`prefetch`/`queue_prefetch`) and the read tools stay available in
every `agent_context`; the writes above (session transcripts, memory mirror,
`robotnotes_remember`/`robotnotes_forget`/`robotnotes_upload_file`) are skipped for a subagent, cron,
or flush context — see Write behavior below for the exact rule.

## Tools

Every tool parameter carries its own description in the schema handed to the
model; the table below is a quick reference.

| Tool                  | Parameters                          | Description                                                                          |
| --------------------- | ------------------------------------ | ------------------------------------------------------------------------------------- |
| `robotnotes_search`   | `query`, `path?`, `limit?`           | Keyword search the shared workspace — not a wildcard; no query means "everything"    |
| `robotnotes_list`     | `path?`, `after?`, `limit?`          | Paginated metadata for every note, optionally under a `path` — use this to enumerate |
| `robotnotes_health`   | none | Inspect local automatic-operation outcomes without a server request |
| `robotnotes_evidence` | `id` | Explicitly inspect a retained JSON snapshot by its SHA-256 digest, including capture and retention metadata |
| `robotnotes_proposals` | `note_id?`, `include_terminal?` | Explicitly list proposal metadata, including terminal audit records when requested |
| `robotnotes_proposal` | `note_id`, `proposal_id` | Explicitly inspect a pending or terminal proposal; candidate text is untrusted and is not automatic recall |
| `robotnotes_note`     | `id`                                 | Fetch a note by id                                                                    |
| `robotnotes_remember` | `title`, `content`, `path?`, `curated_intent?`, `evidence_refs?`          | Store a durable fact as a *new* note; a duplicate title under `path` returns `path_conflict` — search then `robotnotes_append` instead |
| `robotnotes_append`   | `id`, `content`, `curated_intent?`, `evidence_refs?`                      | Append content to an existing note on a new line, instead of duplicating it — via the server's `POST /notes/{id}/append` (falls back to a client-side read-modify-write only against a server old enough to 404/405 that route) |
| `robotnotes_forget`   | `id`, `curated_intent?`, `evidence_refs?`                                 | Remove an ordinary note or propose curated deletion                                                                   |
| `robotnotes_upload_file` | `local_path`, `path?`, `filename?` | Upload a file from the Hermes host into the vault. Only listed when `upload_roots` is set; see [File uploads](#file-uploads) |

### File uploads

`robotnotes_upload_file` is off until `upload_roots` lists at least one absolute
directory:

```json
{ "upload_roots": ["/home/hermes/exports"] }
```

With no roots, the schema and its prompt line are absent and a call returns
`uploads_disabled`. Point roots at dedicated export folders, not `$HOME`.

The model passes `local_path`, never file content. The provider opens the file
on the Hermes host (not the user's device) and streams it to `POST /notes/files`
with the bearer credential, with a 120 s timeout. The result is
`{path, filename, size, content_type}`.

The provider expands `~`, then requires an absolute path. It resolves symlinks
and `..` and accepts only a regular file at or under a resolved root. Hermes'
read denylist (`agent.file_safety`) also applies when available. Rejected paths
make no request:

- `upload_path_invalid`: relative, missing, or not a regular file.
- `upload_path_denied`: outside every root, or blocked by the host denylist.

Server errors pass through: `path_conflict` (409, an existing file is never
overwritten or renamed, so choose another `filename`), `payload_too_large` (413,
the server's max upload size decides), `canonical_note_upload_forbidden` (422,
`.md` files cannot be uploaded as files), and permission denial.

Uploads count as writes and return `read_only` in subagent, cron, and flush
contexts.

## Skill

`register(ctx)` also calls `ctx.register_skill("robot-notes", ...)` when the
host supports it (`hasattr(ctx, "register_skill")`), bundling
[`skills/robot-notes/SKILL.md`](skills/robot-notes/SKILL.md) —
the search-before-create / append-not-duplicate discipline for the
`robotnotes_*` tools above, addressed as `robot_notes:robot-notes`. On a
host without skill support, registration of the memory provider itself is
unaffected.

## Write behavior

Writes are deliberately sparse — this plugin never writes a note per
conversation turn:

- **Recall** searches the workspace before each turn and injects the top
  matches as context; it never blocks a turn on a slow or unreachable
  server.
- **Session end** files or updates one note per session under
  `conversations/<actor>/<session id>`. What leaves the device is a
  readable, bounded transcript built by `robot_notes/transcript.py`, never
  the raw message list:
  - only `user`/`assistant` text is kept — string content, or the `text`
    parts of list-shaped content (tool calls, tool results, images and
    `system` messages are dropped);
  - assistant messages that are only `tool_calls` (no text) are dropped
    entirely;
  - Hermes' own context-compaction handoff summaries are recognized and
    dropped, so a compacted session doesn't file its own compaction
    scaffolding;
  - the `<memory-context>...</memory-context>` block Hermes prepends to a
    user turn with recalled memory is stripped before filing — that block
    is recalled memory, not something the user said;
  - the note opens with a small header (session id, actor, an ISO-8601
    UTC timestamp, turn count) and a one-line title derived from the
    first user message (truncated to 80 characters);
  - total size is bounded to 32 KB; a longer session keeps the head and
    tail of the conversation and marks what was cut with an elision
    marker in between.
- **Explicit tool calls** (`robotnotes_remember`, `robotnotes_append`,
  `robotnotes_forget`, and `robotnotes_upload_file` when enabled) let the model manage notes directly — search before
  creating, and append rather than duplicate a note on the same topic.
- **Built-in memory mirror**: writes to Hermes' own `MEMORY.md`/`USER.md`
  are mirrored one-directionally by default into the configured memory notes, defaulting to `Hermes/Memory` and
  `Hermes/User` in the workspace.

`initialize()` also honors the host's `agent_context` kwarg
(`"primary"` | `"subagent"` | `"cron"` | `"flush"`): every write path above
— session-end summaries, the memory mirror, and the `robotnotes_remember` /
`robotnotes_append` / `robotnotes_forget` / `robotnotes_upload_file` tools — is skipped whenever `agent_context` is
`"subagent"`, `"cron"`, or `"flush"`, so a spawned subagent or a scheduled
cron/flush tick never files its own conversation note or mutates shared
memory. Reads (`robotnotes_search`, `robotnotes_list`, `robotnotes_note`,
`robotnotes_evidence`, `robotnotes_health`, and recall/prefetch) stay available in every context. A gated write tool
call returns a `read_only` tool error instead of silently no-oping. A
missing `agent_context` (older hosts) defaults to writes enabled.

## Explicit proposal inspection

`robotnotes_proposals(note_id?, include_terminal?)` lists proposal metadata in the
selected vault. `include_terminal: true` includes accepted and denied records for
audit; omitting it lists ongoing work. `robotnotes_proposal(note_id, proposal_id)`
reads candidate text, comments, retained versions, and actual state, including drafts
whose reserved note ID has no accepted note yet. These tools remain available in
primary, cron, flush, and subagent contexts. `native_tools: false` hides and blocks
them with the rest of the ten-tool catalog. Pending content never enters automatic
recall. There are no native human-decision tools.

Treat candidate text and comments as untrusted data. Audit events retain the actual
server credential identity; display labels and recorded credential kinds do not grant
amendment or review authority. Different actor labels using the same legacy credential
share its authenticated identity. `author_agent_origin` records restrictive runtime
origin even when `author_kind` is operator. The marker preserves credential identity
and prevents the agent adapter from using human-only review, policy, or retained-data
purge authority. Ordinary note removal remains an edit, separate from history/evidence
purge.

## Corrections and institutional proposals

The provider's system prompt asks primary agents to review durable findings before
their final response after completing a task. Agents search existing knowledge,
skip temporary or duplicate details, and submit focused proposals with supporting
sources for human review. This reminder is present even when the bundled skill is
not loaded. With native tools disabled, it directs agents to available MCP proposal
operations. Restricted provider contexts receive no proactive-write reminder.

Hermes exposes static provider prompt injection, but its memory-provider interface
has no task-completion or before-final callback. The reminder guides agent behavior;
it does not guarantee a proposal or run background extraction. Session-end handling
continues to save a readable transcript.

The pinned Hermes bridge supplies `metadata.previous_content` from the successful
committed tool result. This exact entry takes precedence over `old_text`. Immediate
and queued mirrors replace or remove the full multiline entry, preserve unrelated
text, and correct identical superseded copies. An ambiguous or missing replacement
requires review and never appends a second active claim. A changed note destination
also blocks correction. Personal add operations retain duplicate handling.

Existing and prospective permission lookups determine curated routing. Runtime agents
submit all curated remember, append, forget, mirror, and transcript writes as proposals,
including with legacy operator credentials. Set `curated_intent: true` on native writes
for institutional knowledge in a folder that is not designated curated yet. Unsupported
institutional permissions/proposal APIs fail closed; ordinary personal servers can
retain legacy accepted-write behavior.

A native proposal result contains its real `proposal_id`, `note_id`, `state`, and
`accepted` flag. `accepted: false` means the draft or correction is not accepted;
curated forget leaves the note active until review. `robotnotes_health` distinguishes
`pending_review`, `needs_review`, `denied`, and completed writes. Ordinary accepted
outcomes and successful automatic-write health report `source_unknown: true`.

Optional `evidence_refs` carry exact archive digests, accepted note/block revisions,
conversation identifiers, URLs, or explicit unknown references. Only supplied callback
session/turn/tool/task IDs are retained; the provider does not invent a turn, URL,
archive digest, or source from a later session. Conversation IDs and URLs remain
unverified lineage. New text, corrections, and deletion require human review; attaching
sources does not approve their claims. Source-only automatic approval is a server
policy for verified attachments to unchanged accepted text.

Curated proposals retain source coordinates and prior block revisions in the server's
versioned accepted metadata after acceptance. The active projection follows the current
accepted version; retained historical proposals are audit history. Ordinary personal
writes have unmanaged provenance and explicitly report unknown source, even when a
callback supplied lineage. The plugin does not put that lineage in arbitrary note
properties or maintain another fact store.

Prepared queued effects freeze the body, accepted base, block operations, references,
and idempotency key before RPC. Lost acknowledgements resend the same proposal.
Validated legacy prepared upgrades are persisted before replay; ambiguous legacy
corrections block. A frozen ordinary effect blocks if its destination becomes curated.
The SDK sends `X-Robot-Notes-Agent: true` as a restrictive runtime marker, preserving
credential identity and allowing the server to deny a designation race under its
mutation lock. The marker grants no privilege.

Block plans verify exact body and map hashes and versions, decode UTF-16 spans, and
use real accepted IDs and revisions. Edits to unmapped separators or ambiguous anchors
require precise block review. Read-only agent contexts and disabled native tools keep
their existing gates.

## Development

The test suite (`make test-hermes-plugin` from the repo root, or directly:
`cd hermes-plugin && python3 -m venv .venv && .venv/bin/pip install -q -e
'.[dev]' && .venv/bin/python -m pytest`) runs in two modes:

- **Stub mode** (default, no extra setup): `agent.memory_provider` isn't on
  `PYTHONPATH`, so `MemoryProvider` resolves to this package's own
  `_LocalMemoryProvider` stub. `tests/test_stub_parity.py` and
  `tests/test_memory_manager_contract.py` are skipped in this mode — there's
  no real hermes-agent ABC or `MemoryManager` to check them against.
- **Contract mode**: a real [hermes-agent](https://github.com/NousResearch/hermes-agent)
  checkout is put on `PYTHONPATH`, pinned to the commit in
  [`HERMES_AGENT_SHA`](../HERMES_AGENT_SHA) so results are reproducible. This
  un-skips the parity test (stub vs. the real `MemoryProvider` ABC) and the
  contract test (this provider driven through the real `MemoryManager`:
  `add_provider`, `initialize_all`, `prefetch_all`, `handle_tool_call`,
  `on_memory_write`, `on_session_end`, `shutdown_all`). Run it with:

  ```bash
  make test-hermes-plugin-contract   # from the repo root; clones the pin and runs pytest
  ```

  or manually:

  ```bash
  git clone --depth 1 https://github.com/NousResearch/hermes-agent /tmp/hermes-agent
  cd hermes-plugin
  PYTHONPATH=/tmp/hermes-agent .venv/bin/python -m pytest -v
  ```

  No extra `pip install` of hermes-agent's own dependencies is needed for
  either test — see their docstrings for why a bare `PYTHONPATH` checkout is
  enough. CI runs contract mode against the pin on every `hermes-plugin/`
  change (job `hermes-plugin-contract`) and, separately, weekly against
  hermes-agent's default branch as a non-blocking drift check.

## Testing

`python -m pytest` (from `hermes-plugin/`, or `make test-hermes-plugin` from
the repo root) mocks robot-notes' HTTP API with `respx` — fast, but it can't
catch a mismatch with the real server's behavior.

`tests/e2e/` covers `RobotNotesClient`, `RobotNotesProvider`, and the Claude
Code hook (`claude-plugin/hooks/log_conversation.py`) against an actual
running robot-notes server: real 201/404/409/423 status codes, the real
error envelope shape, and optimistic-concurrency (`If-Match`) behavior. These
are marked `@pytest.mark.e2e`, skipped by default, and only run when both
`ROBOT_NOTES_E2E_BASE_URL` and `ROBOT_NOTES_E2E_API_KEY` point at a live
server:

```bash
# One-shot: starts a server, runs the e2e suite, stops the server.
make test-hermes-plugin-e2e

# Or manually, against a server you already have running:
export ROBOT_NOTES_E2E_BASE_URL=http://127.0.0.1:8080
export ROBOT_NOTES_E2E_API_KEY=dev-secret-do-not-ship
cd hermes-plugin && .venv/bin/python -m pytest -m e2e
```


### Memory health

Call `robotnotes_health()` to inspect automatic memory operations without a server
request. Embedders can call `provider.memory_health()` even when native tools are
disabled. The snapshot contains separate `recall`, `mirror`, and `transcript`
outcomes for the current provider session. It reports the latest started attempt
for each operation, not an audit history or proof that all earlier writes arrived.

Each outcome has a `state`: `not_attempted`, `in_progress`, `failed`, or
`succeeded` for writes. Successful recall uses `empty` or `matched`. A failed
operation adds a `reason` from the client's error categories. For `auth`, check
the configured credentials and permissions. For `network_error`, check server
connectivity. For `circuit_open`, allow the client's cooldown before retrying.

Health contains no prompts, note bodies, server error messages, or credentials.
Trivial prompts and cached recall do not start a new search or change the last
search outcome. The Hermes recall indicator still counts only injected notes;
an empty search or outage does not fabricate a recalled note. Background searches
cannot overwrite a newer attempt's status, and session switches reset health.

`writes_enabled` reflects the provider's context write restrictions.
`retry_queue: "disabled"` means durable automatic writes are disabled. When enabled,
queue metadata reports pending operations, permanent failures, and expired writes.
A successful latest operation alone does not establish delivery of earlier writes.
Successful operation produces no additional log output.

### Durable automatic writes

Set `"durable_writes": true` in `robot_notes.json` to queue automatic memory mirrors and readable session notes on disk. The default is false. Explicit tool calls continue to return their immediate result or error.

The queue lives under `$HERMES_HOME/robot_notes_outbox/<destination-hash>/queue.sqlite`. The destination includes server, vault, actor, credential hash, and available scope identity. Queue files have mode `0600`. Each queue retains at most 1000 operations and 2 MiB for 30 days. Capacity failures and expired writes appear in `robotnotes_health`.

Delivery runs at initialization, when automatic writes arrive, and at turn start. Network failures and server errors remain pending. Authorization failures and conflicts block the queue until corrected. `flush_memory_writes(retry_blocked=True)` explicitly permits another attempt. A prepared note mutation retains its intended content and original version, so a lost acknowledgement cannot reapply a remove selector or duplicate a multiline addition. An intervening edit blocks replay for review.
### Choose memory destinations

Identity scope searches run concurrently with the host profile and secret context.
Results retain configured-root order; a failed scope suppresses the whole recall block.

The default `memory_scope: "shared"` keeps the existing `Hermes/Memory` and
`Hermes/User` mirrors and searches the selected vault. To organize personal and
agent memory separately, configure stable IDs explicitly in `robot_notes.json`:

```json
{
  "base_url": "https://notes.example.com",
  "memory_scope": "identity",
  "user_id": "alice",
  "agent_id": "research-assistant",
  "shared_memory_path": "Team/Knowledge"
}
```

Identity mode mirrors `USER.md` into `Hermes/users/alice/User` and `MEMORY.md`
into `Hermes/agents/research-assistant/Memory`. Each ID must contain 1 to 64 lowercase ASCII
letters, digits, underscores, or hyphens and start with a letter or digit. Keep
these IDs stable across restarts. Uppercase IDs are rejected because the server
checks path collisions without regard to case. They are explicit configuration, independent
of the mutable `actor` attribution label and host-provided identity hints.

Automatic recall searches the user and agent folders, including subfolders.
The optional `shared_memory_path` adds one explicitly shared folder; omit it to
search only the two identity folders. It must be a relative folder without empty
or dot segments. Results interleave user, agent, and shared matches in that
order, deduplicate note IDs, and retain at most five notes. If any scoped search
fails, automatic recall returns no context rather than treating partial results
as a successful search. The existing client timeout applies to each search.

These folders organize retrieval; they do not establish ownership, change server
permissions, or make a fact authoritative. Native search and list tools remain
explicit, credential-authorized operations across the selected vault. Session
transcripts retain their existing actor-scoped destination. Configure server
access separately when users require enforced isolation.

To migrate existing shared mirrors:

1. Read `Hermes/Memory` and `Hermes/User` and decide which entries belong to the
   configured user, agent, or shared knowledge folder.
2. Copy reviewed entries into the chosen destination notes using ordinary note
   tools. Keep the original notes until all clients have been reviewed.
3. Enable identity mode with the same stable IDs and restart the provider.
4. Verify automatic recall and mirror writes before retiring any shared notes.

Changing the configuration does not move, copy, merge, or delete existing notes.
A missing destination is created on the next applicable mirror write. Returning
to shared mode uses the original shared destinations again. Setup preserves these
manually configured fields.


### Optional conversation evidence

Set `"evidence_archive": true` in `robot_notes.json` to capture JSON evidence separately from accepted notes and normal search. `"evidence_retention_days": 30` controls archive and local queue retention. Valid values are integers from 1 through 3650. Capture is disabled by default and unavailable in cron, flush, and subagent contexts.

Completed-turn callbacks durably queue supplied JSON messages without the readable transcript's truncation. Tool results, structured message parts, stable message IDs, and media URL references remain in those snapshots. The provider does not fetch remote media or accept Python objects that cannot be serialized as JSON. When the host omits `messages`, the archive explicitly marks the user and assistant text as `text_fallback`. Identical message lists in one session share a snapshot digest unless supplied IDs distinguish them. The archive records snapshots, not an exact event timeline.

The pinned Hermes checkpoint API v2 hands the provider normalized user and assistant evidence. It omits tool rows, system messages, summaries, and assistant tool-call wrappers without prose. Supported surviving JSON content is retained. Before reporting checkpoint success, the provider requires remote acknowledgement of pending raw snapshots and the supplied normalized checkpoint. A failed write, malformed acknowledgement, expired pending snapshot, or failed local capture prevents success. Checkpoints do not reconstruct evidence that the host never supplied.

Each vault stores evidence in `evidence.db` beside its disposable indexes, outside ordinary content. `PUT /evidence/{sha256}` accepts the exact JSON string in `payload`, `retention_days`, and optional `lineage`. `GET` returns it until expiry. The operator key can purge it with `DELETE`. Expiry or purge removes payload and lineage while retaining a digest tombstone that prevents delayed retries from restoring erased content. Expired server payloads are cleared at startup, during archive operations, and hourly.

Pending evidence lives in `$HERMES_HOME/robot_notes_outbox/<destination-hash>/evidence/queue.sqlite`, with a limit of 1000 snapshots and 32 MiB. Permanent errors block replay. After correcting a credential or server error, `flush_evidence(retry_blocked=True)` permits another attempt. A `capture_failed` marker or an expired-operation count means raw evidence was lost. Required checkpoints remain blocked until an operator inspects and removes that evidence queue directory to acknowledge the loss. Keep the uncompressed host context before that reset. The local queue and remote archive have independent erasure operations.

A successful pre-compression checkpoint returns its exact digest and `host_normalized` capture label after durable acknowledgement. With native tools enabled, `robotnotes_evidence(id)` retrieves that snapshot explicitly and verifies the returned payload digest. Inspection remains available in read-only contexts and when capture is disabled, subject to server credentials. Expired or purged snapshots return a read error. Evidence inspection never enters automatic recall; `native_tools: false` hides and disables this tool along with the rest of the native catalog.
### Bound automatic recall evidence

The following optional settings narrow recall to a task folder and expand evidence:

```json
{
  "recall_path": "projects/launch",
  "recall_max_bytes": 4096,
  "recall_expand_chars": 1000
}
```

`recall_path` intersects the configured identity roots within the selected vault.
An unrelated folder produces no recall. It never grants access or broadens an
identity root. Omit it to retain the configured roots.

`recall_max_bytes` bounds the entire injected UTF-8 text, including note IDs,
titles, paths, and update timestamps. Its range is 0–65536, with 0 preserving the
existing snippet format. This is a byte budget, not a tokenizer-specific token
count. A source whose metadata cannot fit is omitted.

`recall_expand_chars` expands around a search snippet in current note content,
up to 8192 characters per note. It defaults to 0 and requires a positive byte
budget when enabled. Expansion adds up to five note reads, each using the recall
timeout. Any failed read follows the existing recall failure behavior rather
than injecting a partial result. Fetched notes provide current source timestamps.

Run `python -m pytest tests/e2e/test_recall_evidence_e2e.py -s` from `hermes-plugin`
against a disposable server configured through `ROBOT_NOTES_E2E_BASE_URL` and
`ROBOT_NOTES_E2E_API_KEY`. The comparison prints latency and context bytes. In a
local keyword-only run, the default context used 355 bytes and omitted the
supporting tail sentence. Scoped expansion recovered that sentence, excluded the
other folder, and used 941 bytes under a 1400-byte budget. Prefetch took 4.7 ms and
4.8 ms respectively in that single run. These are observations, not thresholds.

This test demonstrates keyword passage expansion. Whole-note semantic embeddings
still truncate long input; no passage vector index or semantic-tail improvement
is claimed. A model-backed comparison using a pinned model remains necessary
before choosing a passage indexing design, tracked in [#378](https://github.com/cedricziel/robot-notes/issues/378). Proposal approval is outside this
feature; it does not introduce a synthetic pending or accepted state.
