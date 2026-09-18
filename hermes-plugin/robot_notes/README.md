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

Copy or symlink this directory into `$HERMES_HOME/plugins/robot_notes/`:

```bash
ln -s "$(pwd)/hermes-plugin/robot_notes" "$HERMES_HOME/plugins/robot_notes"
```

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

| Key        | Where                               | Description                                  |
| ---------- | ----------------------------------- | -------------------------------------------- |
| `base_url` | `robot_notes.json`                  | robot-notes server base URL                  |
| `actor`    | `robot_notes.json`                  | Actor name attributed to this agent's writes |
| `api_key`  | `ROBOT_NOTES_API_KEY` (env, secret) | Bearer credential for every request          |

`robot_notes.json` lives at `$HERMES_HOME/robot_notes.json` and never contains
the API key.

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
- **Session end** files or updates one summary note per session under
  `conversations/<actor>/<session id>`.
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
