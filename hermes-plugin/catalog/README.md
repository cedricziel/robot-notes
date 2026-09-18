# Hermes plugin-catalog submission (prep only)

This directory holds a **draft** of the entry we intend to submit to
[NousResearch/hermes-agent's `plugin-catalog/`](https://github.com/NousResearch/hermes-agent/tree/main/plugin-catalog),
so the Hermes memory-provider docs cover installing `robot_notes` by name
(`hermes plugins install robot_notes`) instead of only by Git URL.

`robot-notes.yaml` here is **not** the upstream file — it is staged so the
diff is obvious when someone opens the real PR against `hermes-agent`. Do not
open that PR yet: the catalog's admission policy requires a real release/tag
(rule 3 of the [catalog README](https://github.com/NousResearch/hermes-agent/blob/main/plugin-catalog/README.md#admission-policy)),
and `sha` below is a placeholder. This is issue #247 in the
[hermes-plugin epic](https://github.com/cedricziel/robot-notes/issues/229) —
the last wave, done once every other hermes-plugin sub-issue has merged and a
release has shipped.

## Steps to submit, after the next release tags

1. **Find the release commit.** Once release-please cuts a tag (e.g. `v0.2.13`)
   that includes the hermes-plugin changes from the epic, resolve its commit:

   ```bash
   git fetch --tags origin
   git rev-parse v0.2.13^{commit}
   ```

2. **Update the draft entry.** In `hermes-plugin/catalog/robot-notes.yaml`,
   replace the placeholder `sha` with that 40-hex commit, and set `version`
   to match `hermes-plugin/robot_notes/plugin.yaml`'s `version` at that same
   commit (release-please keeps both in sync via `x-release-please-version`).
   Re-check the `capabilities` block against `hermes-plugin/robot_notes/tools.py`
   (`TOOL_SCHEMAS`) and `hermes-plugin/robot_notes/plugin.yaml` (`hooks:`,
   `requires_env:`) — the catalog rejects (rule 6) a declaration that doesn't
   match what the plugin actually registers.

3. **Validate locally**, against a checkout of the repo at exactly that
   commit (a fresh clone at the tag, not the worktree with local edits):

   ```bash
   git clone --branch v0.2.13 --depth 1 https://github.com/cedricziel/robot-notes /tmp/robot-notes-release
   cd hermes-plugin && python3 -m venv .venv && .venv/bin/pip install -q -e '.[dev]'

   # Preferred: the real `hermes plugins validate` (manifest + capability
   # probe + security scan), if you have a hermes-agent checkout/venv handy:
   hermes plugins validate /tmp/robot-notes-release/hermes-plugin/robot_notes

   # Structural check of the catalog YAML itself, no hermes-agent install
   # needed beyond PyYAML (this is the same script the admission CI runs):
   git clone --depth 1 https://github.com/NousResearch/hermes-agent /tmp/hermes-agent
   pip install --user pyyaml
   python3 /tmp/hermes-agent/scripts/validate_plugin_catalog.py hermes-plugin/catalog/robot-notes.yaml
   ```

   Both were run against the current `hermes-plugin/robot_notes/` during
   #247's prep (see the epic/#247 PR description for the exact output) and
   passed clean (`verdict: safe`, `OK overall: True`); re-run them at the
   pinned release commit before opening the PR, since the pin — not this
   worktree — is what gets reviewed.

4. **Open the upstream PR.** Fork or branch `NousResearch/hermes-agent`, add
   `plugin-catalog/robot-notes.yaml` (copy the validated contents of
   `hermes-plugin/catalog/robot-notes.yaml` verbatim, minus the prep-only
   header comment), and open a PR against `main` there. Per the catalog's
   admission policy this must come from the plugin's owner/maintainer
   (`cedricziel`), reference the release tag, and note the `subdir:
   hermes-plugin/robot_notes` field — the manifest lives inside this
   monorepo, not at the repo root, so `repo:` alone would resolve to the
   wrong directory. Link back to
   `https://github.com/cedricziel/robot-notes/issues/229` for context.

5. **After merge**, `hermes plugins install robot_notes` works, and this
   repo's own README/plugin docs can start pointing at the catalog name
   instead of (or alongside) the manual install instructions.

## Notes for future SHA bumps

Once the entry is merged upstream, every subsequent robot-notes release that
implementers want catalog users to pick up needs its own small PR to
`hermes-agent` bumping `sha` (and `version`) — the catalog never auto-tracks
a branch tip (see admission policy rule 4). Keep this directory's
`robot-notes.yaml` in sync as the source of truth for what that PR's diff
should look like.
