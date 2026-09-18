"""End-to-end coverage of RobotNotesProvider against a live robot-notes server.

Focuses on the one behavior the epic (#229) flags as untested anywhere else:
calling ``on_session_end`` twice for the same session id (e.g. once before a
`/resume` and once after) must converge on a single note, not create a
second one or silently drop the update.
"""

from __future__ import annotations

import json
import uuid

import pytest

from robot_notes import RobotNotesProvider
from robot_notes.client import RobotNotesClient

pytestmark = pytest.mark.e2e


def _uid() -> str:
    return uuid.uuid4().hex[:12]


def _make_provider(tmp_path, *, base_url, api_key, actor, session_id, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", api_key)
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": base_url, "actor": actor}), encoding="utf-8"
    )
    provider = RobotNotesProvider()
    provider.initialize(session_id, hermes_home=str(tmp_path))
    return provider


def test_handle_tool_call_append_uses_the_server_append_endpoint(
    tmp_path, monkeypatch, e2e_base_url, e2e_api_key, e2e_client: RobotNotesClient
):
    """robotnotes_append (#248) goes straight to `POST /notes/{id}/append` on
    a real server — no local read/If-Match round trip — and lands the same
    single-`\\n` join `NoteWriteService.append` uses everywhere else."""
    actor = f"e2e-provider-{_uid()}"
    note = e2e_client.create_note(title=f"e2e-{_uid()}", content="line one", path=f"e2e-provider-{_uid()}")

    provider = _make_provider(
        tmp_path,
        base_url=e2e_base_url,
        api_key=e2e_api_key,
        actor=actor,
        session_id=f"e2e-session-{_uid()}",
        monkeypatch=monkeypatch,
    )
    try:
        result = json.loads(provider.handle_tool_call("robotnotes_append", {"id": note["id"], "content": "line two"}))
    finally:
        provider.shutdown()

    assert result["content"] == "line one\nline two"
    assert result["version"] == note["version"] + 1


def test_on_session_end_twice_converges_on_one_note(
    tmp_path, monkeypatch, e2e_base_url, e2e_api_key, e2e_client: RobotNotesClient
):
    actor = f"e2e-provider-{_uid()}"
    session_id = f"e2e-session-{_uid()}"

    provider = _make_provider(
        tmp_path, base_url=e2e_base_url, api_key=e2e_api_key, actor=actor, session_id=session_id, monkeypatch=monkeypatch
    )
    try:
        provider.on_session_end([{"role": "user", "content": "first turn"}])
        provider.on_session_end(
            [
                {"role": "user", "content": "first turn"},
                {"role": "assistant", "content": "first reply"},
                {"role": "user", "content": "second turn, after /resume"},
            ]
        )
    finally:
        provider.shutdown()

    conversations_path = f"conversations/{actor}"
    listing = e2e_client.list_notes(path=conversations_path)
    matching = [item for item in listing["items"] if item["title"] == session_id]
    assert len(matching) == 1, f"expected exactly one note for {session_id!r}, found {len(matching)}"

    note = e2e_client.get_note(matching[0]["id"])
    assert note["version"] == 2  # created once (v1), overwritten once (v2) — never a third write
    assert "second turn, after /resume" in note["content"]
