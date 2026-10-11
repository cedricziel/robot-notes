import httpx
import pytest
import respx
from robot_notes import RobotNotesProvider
from robot_notes.client import RobotNotesClient
from robot_notes.config import RobotNotesConfig


def test_recall_configuration_roundtrips(tmp_path):
    configured = RobotNotesConfig.create(
        recall_path="projects/launch", recall_max_bytes=1400, recall_expand_chars=1000
    )
    configured.save(str(tmp_path))
    restored = RobotNotesConfig.load(str(tmp_path))
    assert restored.recall_path == "projects/launch"
    assert restored.recall_max_bytes == 1400
    assert restored.recall_expand_chars == 1000


@pytest.mark.parametrize(
    "options",
    [
        {"recall_path": "../other"},
        {"recall_path": "/root"},
        {"recall_path": "a//b"},
        {"recall_max_bytes": True},
        {"recall_max_bytes": -1},
        {"recall_max_bytes": 65537},
        {"recall_expand_chars": 1},
        {"recall_expand_chars": -1},
    ],
)
def test_invalid_recall_settings_are_rejected(options):
    with pytest.raises(ValueError):
        RobotNotesConfig.create(**options)


@respx.mock
def test_evidence_fetch_uses_recall_timeout():
    route = respx.get("https://notes.example.com/notes/1").respond(
        200, json={"id": "1"}
    )
    client = RobotNotesClient(
        base_url="https://notes.example.com",
        api_key="test",
        actor="test",
        recall_timeout=0.25,
    )
    try:
        client.get_note("1", recall=True)
        assert route.calls.last.request.extensions["timeout"]["read"] == 0.25
    finally:
        client.close()


@respx.mock
def test_failed_expansion_returns_no_partial_evidence(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "test")
    config = RobotNotesConfig.create(
        base_url="https://notes.example.com",
        recall_max_bytes=1000,
        recall_expand_chars=200,
    )
    config.save(str(tmp_path))
    respx.get("https://notes.example.com/search").respond(
        200, json={"items": [{"id": "1", "title": "Evidence", "snippet": "match"}]}
    )
    respx.get("https://notes.example.com/notes/1").mock(
        side_effect=httpx.ReadTimeout("slow")
    )
    provider = RobotNotesProvider()
    try:
        provider.initialize("test", hermes_home=str(tmp_path))
        assert provider.prefetch("match") == ""
    finally:
        provider.shutdown()
