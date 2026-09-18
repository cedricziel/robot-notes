"""End-to-end coverage of claude-plugin/hooks/log_conversation.py's append_line
against a live robot-notes server.

The hook is deliberately stdlib-only (no httpx, no packaging) and is invoked
by Claude Code as a standalone script, never imported as a package — so this
test loads it by file path, the same way it is actually run.
"""

from __future__ import annotations

import importlib.util
import types
import uuid
from pathlib import Path

import pytest

pytestmark = pytest.mark.e2e

_HOOK_PATH = Path(__file__).resolve().parents[3] / "claude-plugin" / "hooks" / "log_conversation.py"


def _load_hook() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("log_conversation_e2e", _HOOK_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def hook() -> types.ModuleType:
    assert _HOOK_PATH.is_file(), f"claude hook not found at {_HOOK_PATH}"
    return _load_hook()


def _uid() -> str:
    return uuid.uuid4().hex[:12]


def test_append_line_creates_then_appends_in_order(hook, e2e_base_url, e2e_api_key, e2e_client):
    actor = f"e2e-hook-{_uid()}"
    session_id = f"e2e-hook-session-{_uid()}"
    path = hook.conversations_path(actor)

    hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, "**user**: hello there")
    hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, "**assistant**: hi, how can I help?")

    note = e2e_client.find_note_by_title(session_id, path=path)
    assert note is not None, "append_line should have created a note titled after the session id"

    fetched = e2e_client.get_note(note["id"])
    content = fetched["content"]
    assert "**user**: hello there" in content
    assert "**assistant**: hi, how can I help?" in content
    # Second append must land after the first, not replace it.
    assert content.index("hello there") < content.index("hi, how can I help?")
    assert fetched["version"] == 2  # one create + one update, never a second create


def test_append_line_uses_a_single_newline_separator(hook, e2e_base_url, e2e_api_key, e2e_client):
    """append_line's fast path is now `POST /notes/{id}/append` (#248), so the
    separator it lands is whatever the server's `NoteWriteService.append`
    inserts — a single ``\\n`` — not the old client-side ``\\n\\n``."""
    actor = f"e2e-hook-{_uid()}"
    session_id = f"e2e-hook-session-{_uid()}"
    path = hook.conversations_path(actor)

    hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, "**user**: hello there")
    hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, "**assistant**: hi, how can I help?")

    note = e2e_client.find_note_by_title(session_id, path=path)
    fetched = e2e_client.get_note(note["id"])
    assert fetched["content"] == "**user**: hello there\n**assistant**: hi, how can I help?"


def test_find_note_by_title_uses_the_server_title_filter(hook, e2e_base_url, e2e_api_key, e2e_client):
    """find_note_by_title's fast path (#248) is the server's `?title=` filter,
    not the paginated folder scan — confirmed here by locating a note the
    scan would also find, through the hook's own function."""
    actor = f"e2e-hook-{_uid()}"
    session_id = f"e2e-hook-session-{_uid()}"
    path = hook.conversations_path(actor)

    hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, "**user**: hi")

    found = hook.find_note_by_title(e2e_base_url, e2e_api_key, actor, session_id, path)
    assert found is not None
    assert found["title"] == session_id


def test_append_line_is_idempotent_note_target_across_calls(hook, e2e_base_url, e2e_api_key, e2e_client):
    """Guards against the exact bug this hook's file lock exists to prevent: two
    events for the same session must never race into two separate notes."""
    actor = f"e2e-hook-{_uid()}"
    session_id = f"e2e-hook-session-{_uid()}"
    path = hook.conversations_path(actor)

    for line in ("**user**: one", "**assistant**: two", "**user**: three"):
        hook.append_line(e2e_base_url, e2e_api_key, actor, session_id, path, line)

    listing = e2e_client.list_notes(path=path)
    matching = [item for item in listing["items"] if item["title"] == session_id]
    assert len(matching) == 1
