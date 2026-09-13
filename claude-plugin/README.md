# robot-notes plugin

A Claude Code plugin providing one skill: how to use the robot-notes MCP
server's note tools correctly (search-before-create, `append_to_note` vs.
`update_note`, optimistic concurrency, editor locks, folder paths, and
error handling).

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

This plugin does not itself configure an MCP server connection — it
assumes the robot-notes tools are already available (e.g. via a
first-party MCP connector or a `.mcp.json` entry elsewhere) and only
teaches an agent how to use them well.
