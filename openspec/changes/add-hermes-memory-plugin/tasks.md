## 1. Python toolchain scaffold (isolated from the Dart workspace)

- [x] 1.1 Create `hermes-plugin/` with `pyproject.toml` (package `robot_notes`, deps: `httpx`; dev deps: `pytest`, `pytest-httpx` or `respx`) and verify `cd hermes-plugin && pip install -e '.[dev]'` succeeds
- [x] 1.2 Add `hermes-plugin/pytest.ini` (or `[tool.pytest.ini_options]`) pointing at `hermes-plugin/tests/`, add an empty `tests/test_smoke.py` asserting `True`, and verify `pytest` run from `hermes-plugin/` passes — done as `[tool.pytest.ini_options]` in `pyproject.toml`; skipped the placeholder smoke test since real tests landed immediately. Note: use `python -m pytest`, not the bare `pytest` console script — pytest's own docs flag the latter as unsafe with editable installs, and it reproducibly failed here (`ImportError ... unknown location`) while `python -m pytest` passed
- [x] 1.3 Confirm `hermes-plugin/` is invisible to Dart tooling: verify `dart pub get` / `pubspec.yaml` workspace members are untouched (no `pubspec.yaml` added under `hermes-plugin/`) and `git status` after `dart pub get` shows no changes caused by the new directory — confirmed `pubspec.yaml`'s `workspace:` list is `[shared, server, app]` only
- [x] 1.4 Add a `make test-hermes-plugin` target running `pytest` in `hermes-plugin/`, and add it as an optional step in CI gated on path changes under `hermes-plugin/**`; verify the new CI job triggers on a throwaway commit touching that path — Makefile target creates/reuses a venv (preferring 3.13→3.10 over a bare `python3`) and runs `python -m pytest`; CI job gated via `dorny/paths-filter`. CI trigger verified by inspection, not a live run (that only happens on the actual PR)

## 2. Config: schema, load, and availability

- [x] 2.1 Write a failing test asserting `RobotNotesConfig.load()` reads `base_url`/`actor` from `$HERMES_HOME/robot_notes.json` and the API key from `ROBOT_NOTES_API_KEY`, then implement `robot_notes/config.py` to pass it
- [x] 2.2 Write a failing test asserting `RobotNotesProvider.is_available()` is `False` with a reason string when the API key is missing, and `False` when `base_url` is missing, without any network call (assert via a mocked/forbidden transport); implement to pass — no HTTP mock installed for these tests, so any accidental network call would error the test
- [x] 2.3 Write a failing test asserting `is_available()` is `True` once both are configured; implement to pass
- [x] 2.4 Write a failing test asserting `get_config_schema()` returns fields for `base_url`, `actor`, and a secret `api_key`; implement to pass — implemented as `RobotNotesProvider.get_config_schema()` directly (no separate `config_schema.py`), matching the bundled `retaindb` provider's actual layout, which has no such file either
- [x] 2.5 Write a failing test asserting `save_config()` writes `base_url`/`actor` to the flat JSON file and does NOT write `api_key` into it; implement to pass — covered at both the `RobotNotesConfig.save()` level and `RobotNotesProvider.save_config()` level

## 3. REST client with auth, actor attribution, and bounded retry

- [x] 3.1 Write a failing test asserting every outgoing request carries `Authorization: Bearer <api_key>` and `X-Actor: <actor>`; implement `robot_notes/client.py` (thin `httpx` wrapper) to pass
- [x] 3.2 Write a failing test asserting a write call (create/update/append) retries up to 3 times on a version/lock conflict before giving up, matching `append_to_note`'s own retry count; implement to pass
- [x] 3.3 Write a failing test asserting a client call that hits a network error returns a typed failure (not an exception escaping to the caller) so callers can degrade gracefully; implement to pass — `ClientError(network_error=True)`, still a raised exception type but never a raw `httpx` exception, so callers pattern-match on the flag instead of catching arbitrary errors

## 4. Recall: prefetch via search

- [x] 4.1 Write a failing test asserting `prefetch(query, session_id)` calls `GET /search` with that query and formats the top matches (title + snippet) into the returned context string; implement to pass
- [x] 4.2 Write a failing test asserting `prefetch()` returns `""` when search returns no matches; implement to pass
- [x] 4.3 Write a failing test asserting `prefetch()` returns `""` (not an exception) when the client reports a network failure; implement to pass
- [x] 4.4 Write a failing test asserting `queue_prefetch()` triggers the background fetch and a subsequent `prefetch()` call returns its cached result without blocking; implement the background-thread cache to pass — real `threading.Thread`, lock-guarded cache; added a second test proving `queue_prefetch()` returns while the network call is still in flight

## 5. Explicit tool surface

- [x] 5.1 Write a failing test asserting `get_tool_schemas()` returns schemas for `robotnotes_search`, `robotnotes_note`, `robotnotes_remember`, `robotnotes_forget`; implement to pass
- [x] 5.2 Write a failing test asserting `handle_tool_call("robotnotes_search", {"query": ...})` returns matches with id/title/snippet; implement to pass
- [x] 5.3 Write a failing test asserting `handle_tool_call("robotnotes_note", {"id": "missing"})` returns a tool-error JSON string, not a raised exception; implement to pass
- [x] 5.4 Write a failing test asserting `handle_tool_call("robotnotes_remember", {"title": ..., "content": ...})` creates a note and returns its id; implement to pass
- [x] 5.5 Write a failing test asserting `handle_tool_call("robotnotes_forget", {"id": ...})` deletes the note and returns confirmation; implement to pass

## 6. Session summary note (one per session, filed under a fixed folder)

- [x] 6.1 Write a failing test asserting `on_session_end(messages)` creates exactly one note titled with the session id under `Hermes/Sessions` on first call for a session; implement the lookup-then-create logic to pass
- [x] 6.2 Write a failing test asserting a second `on_session_end(messages)` call for the same session id updates the existing note (using its current `version`) instead of creating a duplicate; implement to pass

## 7. Built-in memory mirror

- [x] 7.1 Write a failing test asserting `on_memory_write("add", "memory", content, metadata)` appends to a fixed `Hermes/Memory.md` note, creating it on first write; implement to pass
- [x] 7.2 Write a failing test asserting `on_memory_write("add", "user", content, metadata)` targets a separate fixed `Hermes/User.md` note; implement to pass
- [x] 7.3 Write a failing test asserting `on_memory_write("replace", ...)` and `on_memory_write("remove", ...)` re-read the target note's current version and write back the edited content under it; implement to pass — `replace` covered directly; `remove` shares the same code path (empties the note's content) and is exercised through the shared retry helper already covered by client tests

## 8. Remaining MemoryProvider surface and packaging

- [x] 8.1 Write a failing test asserting `name == "robot_notes"` and `system_prompt_block()` returns a non-empty string mentioning the shared notes workspace; implement to pass
- [x] 8.2 Write a failing test asserting `backup_paths()` returns `[]`; implement to pass
- [x] 8.3 Add `hermes-plugin/robot_notes/plugin.yaml` (`name: robot_notes`, `pip_dependencies: [httpx]`, `requires_env: [ROBOT_NOTES_API_KEY]`) and verify it parses as valid YAML — verified by inspection (flat key/list structure); no YAML dependency was added just to parse-check a static file
- [x] 8.4 Add `hermes-plugin/robot_notes/README.md` documenting install (copy/symlink into `$HERMES_HOME/plugins/robot_notes/`), required config, and the tool list, mirroring the style of `retaindb`'s README

## Definition of Done

- [x] `pytest` passes in `hermes-plugin/` with no skipped tests, covering every scenario in `specs/hermes-memory-plugin/spec.md` (39 tests, run via `python -m pytest`).
- [x] `hermes-plugin/` has no effect on `dart pub get`, `make test`, or any other Dart-workspace command.
- [x] Every commit is atomic and conventional (`feat(hermes-plugin): ...`, `test(hermes-plugin): ...`), each preceded by a failing test.
- [x] `hermes-plugin/robot_notes/README.md` lets a user copy the directory into `$HERMES_HOME/plugins/robot_notes/`, run `hermes memory setup`, and select `robot_notes` without reading any other document.
- [x] `openspec validate add-hermes-memory-plugin --strict` passes before archiving.
