# robot-notes plugin

A Claude Code plugin providing:

- A skill teaching how to use the robot-notes MCP server's note tools
  correctly (search-before-create, `append_to_note` vs. `update_note`,
  optimistic concurrency, editor locks, folder paths, and error handling).
- An optional hook that continuously logs the current session's
  conversation into a robot-notes note as it happens.

## Install

```bash
claude --plugin-dir ./claude-plugin
```

or add `claude-plugin/` as a marketplace entry / local plugin path per
your usual Claude Code plugin workflow.

## Contents

- `skills/robot-notes/SKILL.md` — core workflow rules and tool catalog.
- `skills/robot-notes/references/errors.md` — full error-code reference.
- `skills/robot-notes/references/connecting.md` — how to authenticate a
  new MCP client against a robot-notes server (OAuth vs. static key).
- `hooks/hooks.json` + `hooks/log_conversation.py` — the conversation
  logging hook, see below.

This plugin does not itself configure an MCP server connection for the
skill above — it assumes the robot-notes tools are already available
(e.g. via a first-party MCP connector or a `.mcp.json` entry elsewhere)
and only teaches an agent how to use them well. The hook is independent
of that: it talks to robot-notes' REST API directly, the same way
`hermes-plugin/` does, and needs its own credentials (below).

## Conversation logging hook

Fires on `UserPromptSubmit` and `Stop` and appends one line per prompt
or assistant reply to a note titled with the session id, filed under
`conversations/<actor>/<session_id>` in the workspace — one note per
session, scoped by actor, continuously appended to rather than written
once at the end.

**Opt-in.** The hook no-ops silently unless both env vars are set:

```bash
export ROBOT_NOTES_BASE_URL=https://notes.example.com
export ROBOT_NOTES_API_KEY=rn_your_secret
# optional, defaults to "claude-code":
export ROBOT_NOTES_ACTOR=cedric
```

It talks to robot-notes' plain REST API (`/notes`, no MCP client, no
extra Python dependencies — stdlib `urllib` only) and does the actual
network request in a detached background process, so a slow or
unreachable server never adds latency to a turn. Every failure is
swallowed — a note never gets written twice in a way that blocks the
session, and a robot-notes outage never blocks Claude Code.

Because every prompt and reply gets sent to the configured robot-notes
server, only enable this against a workspace you're comfortable logging
conversations into.

Run its tests with:

```bash
cd claude-plugin/hooks && python3 -m unittest test_log_conversation -v
```
