import json

import httpx
import respx

from robot_notes import RobotNotesProvider
from robot_notes.breaker import CircuitBreaker


def make_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(json.dumps({"base_url": "https://notes.example.com"}))
    provider = RobotNotesProvider()
    provider.initialize("session-1", hermes_home=str(tmp_path))
    return provider


@respx.mock
def test_recall_health_outage_open_circuit_and_empty_recovery(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    clock = [0.0]
    provider._client._breaker = CircuitBreaker(threshold=1, cooldown=10, clock=lambda: clock[0])
    route = respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("private prompt"))
    assert provider.prefetch("project decisions") == ""
    assert provider.memory_health()["recall"] == {"state": "failed", "reason": "network_error"}
    assert provider.prefetch("project decisions") == ""
    assert provider.memory_health()["recall"] == {"state": "failed", "reason": "circuit_open"}
    clock[0] = 11
    route.mock(return_value=httpx.Response(200, json={"items": []}))
    assert provider.prefetch("project decisions") == ""
    assert provider.memory_health()["recall"] == {"state": "empty"}
    assert provider.recall_status() is None


@respx.mock
def test_auth_failure_and_health_tool_do_not_expose_response_details(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(403, json={"error": "private content"}))
    provider.prefetch("secret prompt")
    result = json.loads(provider.handle_tool_call("robotnotes_health", {}))
    assert result["recall"] == {"state": "failed", "reason": "auth"}
    assert "secret" not in json.dumps(result)
    assert "private" not in json.dumps(result)


@respx.mock
def test_failed_automatic_write_is_visible_and_recovery_is_independent(tmp_path, monkeypatch, caplog):
    provider = make_provider(tmp_path, monkeypatch)
    route = respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(403, json={"error": "private content"}))
    provider.on_memory_write("add", "memory", "secret memory")
    assert provider.memory_health()["mirror"] == {"state": "failed", "reason": "auth"}
    assert "private content" not in caplog.text
    assert "secret memory" not in caplog.text
    route.mock(return_value=httpx.Response(200, json={"items": []}))
    respx.post("https://notes.example.com/notes").mock(return_value=httpx.Response(201, json={"id": "01NEW"}))
    provider.on_session_end([{"role": "user", "content": "secret transcript"}])
    assert provider.memory_health()["transcript"] == {"state": "succeeded", "source_unknown": True}
    assert provider.memory_health()["mirror"]["state"] == "failed"
    provider.on_memory_write("add", "memory", "secret memory")
    assert provider.memory_health()["mirror"] == {"state": "succeeded", "source_unknown": True}


@respx.mock
def test_successful_recall_keeps_host_count_and_trivial_prompts_preserve_health(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(
        200, json={"items": [{"id": "01NOTE", "title": "Decision", "snippet": "Use SQLite"}]}
    ))
    provider.prefetch("database choice")
    assert provider.memory_health()["recall"] == {"state": "matched"}
    assert provider.recall_status().count == 1
    provider.prefetch("ok")
    assert provider.recall_status() is None
    assert provider.memory_health()["recall"] == {"state": "matched"}


@respx.mock
def test_session_switch_discards_inflight_health(tmp_path, monkeypatch):
    import threading

    provider = make_provider(tmp_path, monkeypatch)
    entered, release = threading.Event(), threading.Event()

    def slow_search(request):
        entered.set()
        assert release.wait(3)
        return httpx.Response(403)

    respx.get("https://notes.example.com/search").mock(side_effect=slow_search)
    provider.queue_prefetch("database choice", session_id="session-1")
    assert entered.wait(3)
    thread = provider._prefetch_thread
    provider.on_session_switch("session-2")
    release.set()
    thread.join(3)
    assert not thread.is_alive()
    assert provider.memory_health()["recall"] == {"state": "not_attempted"}


@respx.mock
def test_failed_transcript_is_visible_without_logging_session_or_error_body(tmp_path, monkeypatch, caplog):
    provider = make_provider(tmp_path, monkeypatch)
    provider.on_session_switch("private-session-id")
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(403, json={"error": "private response"}))
    provider.on_session_end([{"role": "user", "content": "private conversation"}])
    assert provider.memory_health()["transcript"] == {"state": "failed", "reason": "auth"}
    assert "private" not in caplog.text


def test_health_snapshot_cannot_mutate_provider_state(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    snapshot = provider.memory_health()
    snapshot["recall"]["state"] = "matched"
    assert provider.memory_health()["recall"] == {"state": "not_attempted"}
    assert snapshot["retry_queue"] == "disabled"


@respx.mock
def test_old_search_failure_cannot_replace_newer_success(tmp_path, monkeypatch):
    import threading

    provider = make_provider(tmp_path, monkeypatch)
    entered, release = threading.Event(), threading.Event()

    def slow_search(request):
        entered.set()
        assert release.wait(3)
        return httpx.Response(403)

    respx.get("https://notes.example.com/search", params={"q": "old query", "limit": 5}).mock(side_effect=slow_search)
    respx.get("https://notes.example.com/search", params={"q": "new query", "limit": 5}).mock(
        return_value=httpx.Response(200, json={"items": []})
    )
    provider.queue_prefetch("old query", session_id="session-1")
    assert entered.wait(3)
    thread = provider._prefetch_thread
    provider.prefetch("new query", session_id="session-1")
    release.set()
    thread.join(3)
    assert not thread.is_alive()
    assert provider.memory_health()["recall"] == {"state": "empty"}


@respx.mock
def test_health_inspection_needs_no_server_request(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    provider.initialize("subagent", hermes_home=str(tmp_path), agent_context="subagent")
    result = json.loads(provider.handle_tool_call("robotnotes_health", {}))
    assert result["writes_enabled"] is False
    assert result["mirror"] == {"state": "not_attempted"}
    assert result["recall"] == {"state": "not_attempted"}
    assert len(respx.calls) == 0
