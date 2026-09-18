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

`hermes memory setup` only prompts for `base_url` and the API key — the
schema is kept minimal per the developer guide, and `actor` is optional with
a sane default. Set it by hand in `robot_notes.json` (see below) if the
default is not right for your setup.

| Key        | Where                                | Description                          |
| ---------- | ------------------------------------- | ------------------------------------ |
| `base_url` | `robot_notes.json`                    | robot-notes server base URL          |
| `api_key`  | `ROBOT_NOTES_API_KEY` (env, secret)   | Bearer credential for every request  |

## `robot_notes.json` reference

Non-secret config lives at `$HERMES_HOME/robot_notes.json` and never contains
the API key:

| Key        | Required | Default   | Description                                                        |
| ---------- | -------- | --------- | -------------------------------------------------------------------- |
| `base_url` | Yes      | —         | robot-notes server base URL, e.g. `https://notes.example.com`      |
| `actor`    | No       | `hermes`  | Actor name attributed to this agent's writes (sent as `X-Actor`); also scopes the per-session summary note under `conversations/<actor>/` |

```json
{
  "base_url": "https://notes.example.com",
  "actor": "hermes"
}
```

## Data sent to the server

Everything this plugin sends to robot-notes goes over the plain REST API
above (bearer key + `X-Actor` header, no additional client). Nothing is sent
to any service other than the `base_url` configured above.

- **Recall queries** — `prefetch`/`queue_prefetch` send the query text for
  the current turn to `GET /search`. robot-notes returns matching note
  titles and snippets only; the response is injected as context, nothing is
  written back.
- **Session transcripts** — `on_session_end` sends the session's messages as
  the content of one summary note per session, under
  `conversations/<actor>/<session id>`. This currently includes the raw
  role/content of every message in the session, so treat the robot-notes
  workspace as within the conversation's trust boundary.
- **Built-in memory mirror** — content written to Hermes' own
  `MEMORY.md`/`USER.md` is mirrored one-directionally into
  `Hermes/Memory.md`/`Hermes/User.md` notes (see Write behavior below);
  whatever text lands in those files is sent to the server.
- **Explicit tool writes** — `robotnotes_remember` sends the model-authored
  `title`/`content` as a new note; `robotnotes_forget` sends a note id to
  delete. `robotnotes_note`/`robotnotes_list` are read-only and only fetch
  data, they send no new content.

Recall (`prefetch`/`queue_prefetch`) and the read tools stay available in
every `agent_context`; the writes above (session transcripts, memory mirror,
`robotnotes_remember`/`robotnotes_forget`) are skipped for a subagent, cron,
or flush context — see Write behavior below for the exact rule.

## Tools

| Tool                  | Description                                                                          |
| --------------------- | ------------------------------------------------------------------------------------- |
| `robotnotes_search`   | Keyword search the shared workspace — not a wildcard; no query means "everything"    |
| `robotnotes_list`     | Paginated metadata for every note, optionally under a `path` — use this to enumerate |
| `robotnotes_note`     | Fetch a note by id                                                                    |
| `robotnotes_remember` | Store a durable fact as a new note                                                    |
| `robotnotes_forget`   | Delete a note by id                                                                   |

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
- **Explicit tool calls** (`robotnotes_remember`, `robotnotes_forget`) let
  the model manage notes directly.
- **Built-in memory mirror**: writes to Hermes' own `MEMORY.md`/`USER.md`
  are mirrored one-directionally into `Hermes/Memory.md` and
  `Hermes/User.md` in the workspace.

`initialize()` also honors the host's `agent_context` kwarg
(`"primary"` | `"subagent"` | `"cron"` | `"flush"`): every write path above
— session-end summaries, the memory mirror, and the `robotnotes_remember` /
`robotnotes_forget` tools — is skipped whenever `agent_context` is
`"subagent"`, `"cron"`, or `"flush"`, so a spawned subagent or a scheduled
cron/flush tick never files its own conversation note or mutates shared
memory. Reads (`robotnotes_search`, `robotnotes_list`, `robotnotes_note`,
and recall/prefetch) stay available in every context. A gated write tool
call returns a `read_only` tool error instead of silently no-oping. A
missing `agent_context` (older hosts) defaults to writes enabled.

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
