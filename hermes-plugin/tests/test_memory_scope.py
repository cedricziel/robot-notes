import json

import httpx
import pytest
import respx

from robot_notes import RobotNotesProvider
from robot_notes.config import RobotNotesConfig


def identity_config(**kwargs):
    return RobotNotesConfig.create(memory_scope="identity", user_id="alice", agent_id="assistant", **kwargs)


def test_identity_destinations_and_recall_roots():
    config = identity_config(shared_memory_path="Team/Knowledge")
    assert config.memory_note == {"path": "Hermes/agents/assistant", "title": "Memory"}
    assert config.user_note == {"path": "Hermes/users/alice", "title": "User"}
    assert config.recall_paths == ("Hermes/users/alice", "Hermes/agents/assistant", "Team/Knowledge")


def test_shared_defaults_preserve_existing_notes_and_recall():
    config = RobotNotesConfig.create()
    assert config.memory_note == {"path": "Hermes", "title": "Memory"}
    assert config.user_note == {"path": "Hermes", "title": "User"}
    assert config.recall_paths == (None,)


@pytest.mark.parametrize("identity", ["", "../alice", "a/b", "a\\b", ".", "alice bob", "a\n"])
def test_identity_requires_unambiguous_path_safe_identifiers(identity):
    with pytest.raises(ValueError):
        RobotNotesConfig.create(memory_scope="identity", user_id=identity, agent_id="assistant")


@pytest.mark.parametrize("path", ["/", "/Team", "../Team", "Team/..", "Team//Notes", "Team\\Notes"])
def test_shared_path_cannot_escape_its_explicit_relative_folder(path):
    with pytest.raises(ValueError):
        identity_config(shared_memory_path=path)


def test_scope_round_trip_and_wizard_preserve_identity(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "test-key")
    identity_config(base_url="https://notes.example.com", shared_memory_path="Team").save(str(tmp_path))
    provider = RobotNotesProvider()
    provider.save_config({"base_url": "https://other.example.com"}, str(tmp_path))
    config = RobotNotesConfig.load(str(tmp_path))
    assert config.memory_scope == "identity"
    assert config.user_id == "alice"
    assert config.agent_id == "assistant"
    assert config.recall_paths == ("Hermes/users/alice", "Hermes/agents/assistant", "Team")


def make_provider(tmp_path, monkeypatch, user_id="alice", agent_id="assistant"):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "test-key")
    RobotNotesConfig.create(
        base_url="https://notes.example.com", actor="same-attribution",
        memory_scope="identity", user_id=user_id, agent_id=agent_id,
        shared_memory_path="Team",
    ).save(str(tmp_path))
    provider = RobotNotesProvider()
    provider.initialize("session", hermes_home=str(tmp_path))
    return provider


@respx.mock
def test_mirrors_follow_configured_identity_not_actor(tmp_path, monkeypatch):
    alice = make_provider(tmp_path / "alice", monkeypatch)
    bob = make_provider(tmp_path / "bob", monkeypatch, user_id="bob", agent_id="reviewer")
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    creates = respx.post("https://notes.example.com/notes").mock(return_value=httpx.Response(201, json={"id": "01NOTE"}))
    alice.on_memory_write("add", "user", "Alice preference")
    bob.on_memory_write("add", "memory", "Reviewer fact")
    assert json.loads(creates.calls[0].request.content)["path"] == "Hermes/users/alice"
    assert json.loads(creates.calls[1].request.content)["path"] == "Hermes/agents/reviewer"
    assert "Hermes/users/alice/User" in alice.system_prompt_block()
    assert "Hermes/agents/reviewer/Memory" in bob.system_prompt_block()


@respx.mock
def test_identity_recall_merges_selected_roots_without_duplicates(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    search = respx.get("https://notes.example.com/search").mock(side_effect=[
        httpx.Response(200, json={"items": [{"id": "USER", "title": "User", "snippet": "preference"}]}),
        httpx.Response(200, json={"items": [{"id": "AGENT", "title": "Memory", "snippet": "agent fact"}]}),
        httpx.Response(200, json={"items": [{"id": "USER", "title": "Duplicate"}, {"id": "SHARED", "title": "Shared"}]}),
    ])
    result = provider.prefetch("project decision")
    assert [call.request.url.params["path"] for call in search.calls] == [
        "Hermes/users/alice", "Hermes/agents/assistant", "Team",
    ]
    assert "preference" in result and "agent fact" in result and "Shared" in result
    assert "Duplicate" not in result
    assert provider.recall_status().count == 3


@respx.mock
def test_partial_scope_failure_does_not_report_successful_recall(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    respx.get("https://notes.example.com/search").mock(side_effect=[
        httpx.Response(200, json={"items": [{"id": "USER", "title": "User"}]}),
        httpx.Response(403),
    ])
    assert provider.prefetch("project decision") == ""
    assert provider.recall_status() is None
