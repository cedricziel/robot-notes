import json

import httpx
import pytest
import respx

from robot_notes import RobotNotesProvider

UPLOAD_URL = "https://notes.example.com/notes/files"


def _provider(tmp_path, monkeypatch, *, roots=None, agent_context="primary"):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    home = tmp_path / "home"
    home.mkdir()
    config = {"base_url": "https://notes.example.com"}
    if roots is not None:
        config["upload_roots"] = roots
    (home / "robot_notes.json").write_text(json.dumps(config), encoding="utf-8")
    provider = RobotNotesProvider()
    provider.initialize("session-1", hermes_home=str(home), agent_context=agent_context)
    return provider


@pytest.fixture
def exports(tmp_path):
    folder = tmp_path / "exports"
    folder.mkdir()
    (folder / "chart.png").write_bytes(b"png-bytes")
    return folder


def _names(provider):
    return {schema["name"] for schema in provider.get_tool_schemas()}


def test_tool_is_hidden_and_disabled_without_roots(tmp_path, monkeypatch, exports):
    provider = _provider(tmp_path, monkeypatch)

    assert "robotnotes_upload_file" not in _names(provider)
    assert "robotnotes_upload_file" not in provider.system_prompt_block()
    with respx.mock(assert_all_called=False) as mock:
        result = json.loads(provider.handle_tool_call(
            "robotnotes_upload_file", {"local_path": str(exports / "chart.png")}))
    assert result["code"] == "uploads_disabled"
    assert not mock.calls


def test_tool_is_advertised_with_roots(tmp_path, monkeypatch, exports):
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)])

    assert "robotnotes_upload_file" in _names(provider)
    block = provider.system_prompt_block()
    assert "robotnotes_upload_file" in block
    assert str(exports) in block


@respx.mock
def test_upload_streams_the_file_and_returns_only_metadata(tmp_path, monkeypatch, exports):
    route = respx.post(UPLOAD_URL).mock(return_value=httpx.Response(201, json={
        "path": "Hermes/exports", "filename": "chart.png", "size": 9, "content_type": "image/png"}))
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)])

    result = json.loads(provider.handle_tool_call(
        "robotnotes_upload_file", {"local_path": str(exports / "chart.png"), "path": "Hermes/exports"}))

    assert result == {"path": "Hermes/exports", "filename": "chart.png", "size": 9, "content_type": "image/png"}
    body = route.calls.last.request.read()
    assert b'filename="chart.png"' in body
    assert b"png-bytes" in body


@respx.mock
def test_upload_uses_the_given_filename(tmp_path, monkeypatch, exports):
    route = respx.post(UPLOAD_URL).mock(return_value=httpx.Response(201, json={
        "path": "", "filename": "q3.png", "size": 9, "content_type": "image/png"}))
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)])

    provider.handle_tool_call("robotnotes_upload_file",
                              {"local_path": str(exports / "chart.png"), "filename": "q3.png"})

    assert b'filename="q3.png"' in route.calls.last.request.read()


def test_path_outside_roots_is_denied_without_a_request(tmp_path, monkeypatch, exports):
    (tmp_path / "secret.txt").write_text("nope")
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)])

    with respx.mock(assert_all_called=False) as mock:
        result = json.loads(provider.handle_tool_call(
            "robotnotes_upload_file", {"local_path": str(tmp_path / "secret.txt")}))

    assert result["code"] == "upload_path_denied"
    assert not mock.calls


@pytest.mark.parametrize("agent_context", ["subagent", "cron", "flush"])
def test_read_only_contexts_refuse_uploads(tmp_path, monkeypatch, exports, agent_context):
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)], agent_context=agent_context)

    result = json.loads(provider.handle_tool_call(
        "robotnotes_upload_file", {"local_path": str(exports / "chart.png")}))

    assert result["code"] == "read_only"


@respx.mock
def test_name_collision_surfaces_path_conflict(tmp_path, monkeypatch, exports):
    respx.post(UPLOAD_URL).mock(return_value=httpx.Response(409, json={"error": "path_conflict"}))
    provider = _provider(tmp_path, monkeypatch, roots=[str(exports)])

    result = json.loads(provider.handle_tool_call(
        "robotnotes_upload_file", {"local_path": str(exports / "chart.png")}))

    assert result["code"] == "path_conflict"
