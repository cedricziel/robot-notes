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
from robot_notes.client import ClientError, RobotNotesClient

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


@pytest.mark.parametrize("creator", ["agent", "external"])
def test_forget_deletes_credential_authorized_notes_regardless_of_creator(
    tmp_path, monkeypatch, e2e_base_url, e2e_api_key, e2e_client, creator
):
    provider = _make_provider(
        tmp_path, base_url=e2e_base_url, api_key=e2e_api_key,
        actor=f"e2e-provider-{_uid()}", session_id=f"e2e-session-{_uid()}",
        monkeypatch=monkeypatch,
    )
    try:
        if creator == "agent":
            note = json.loads(provider.handle_tool_call(
                "robotnotes_remember", {"title": f"e2e-{_uid()}", "content": "Disposable memory"}
            ))
        else:
            note = e2e_client.create_note(title=f"e2e-{_uid()}", content="Externally created memory")

        result = json.loads(provider.handle_tool_call("robotnotes_forget", {"id": note["id"]}))

        assert result == {"source_unknown": True}
        with pytest.raises(ClientError) as exc:
            e2e_client.get_note(note["id"])
        assert exc.value.not_found
    finally:
        provider.shutdown()


def test_identity_recall_separates_users_and_includes_explicit_shared_notes(
    tmp_path, monkeypatch, e2e_base_url, e2e_api_key, e2e_client
):
    from robot_notes.config import RobotNotesConfig

    marker = f"scope{_uid()}"
    alice_id, bob_id = f"alice-{_uid()}", f"bob-{_uid()}"
    shared_path = f"e2e-shared-{_uid()}"
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", e2e_api_key)
    alice_home, bob_home = tmp_path / "alice", tmp_path / "bob"
    RobotNotesConfig.create(
        base_url=e2e_base_url, actor="same-actor", memory_scope="identity",
        user_id=alice_id, agent_id=alice_id, shared_memory_path=shared_path,
    ).save(str(alice_home))
    RobotNotesConfig.create(
        base_url=e2e_base_url, actor="same-actor", memory_scope="identity",
        user_id=bob_id, agent_id=bob_id, shared_memory_path=shared_path,
    ).save(str(bob_home))
    alice, bob = RobotNotesProvider(), RobotNotesProvider()
    alice.initialize("alice-session", hermes_home=str(alice_home))
    bob.initialize("bob-session", hermes_home=str(bob_home))
    try:
        alice.on_memory_write("add", "user", f"{marker} Alice preference")
        bob.on_memory_write("add", "user", f"{marker} Bob preference")
        e2e_client.create_note(title="Shared", path=shared_path, content=f"{marker} Shared decision")
        e2e_client.create_note(title="Outsider", path=f"Hermes/users/{alice_id}-other", content=f"{marker} Outsider")

        alice_recall, bob_recall = alice.prefetch(marker), bob.prefetch(marker)

        assert "Alice preference" in alice_recall and "Shared decision" in alice_recall
        assert "Bob preference" not in alice_recall and "Outsider" not in alice_recall
        assert "Bob preference" in bob_recall and "Shared decision" in bob_recall
        assert "Alice preference" not in bob_recall
    finally:
        alice.shutdown()
        bob.shutdown()
