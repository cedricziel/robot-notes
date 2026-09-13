import json
import threading

import httpx
import pytest
import respx

from robot_notes import RobotNotesConfig, RobotNotesProvider


@pytest.fixture
def provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize("session-1", hermes_home=str(tmp_path))
    return p


def test_name():
    assert RobotNotesProvider().name == "robot_notes"


def test_is_available_false_without_api_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("ROBOT_NOTES_API_KEY", raising=False)
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com"}), encoding="utf-8"
    )
    provider = RobotNotesProvider()

    assert provider.is_available() is False
    assert "ROBOT_NOTES_API_KEY" in provider.unavailable_reason()


def test_is_available_true_when_configured(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com"}), encoding="utf-8"
    )
    provider = RobotNotesProvider()

    assert provider.is_available() is True


def test_system_prompt_block_mentions_shared_workspace(provider):
    assert "robot-notes" in provider.system_prompt_block()


def test_backup_paths_is_empty(provider):
    assert provider.backup_paths() == []


@respx.mock
def test_prefetch_formats_search_results(provider):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "1", "title": "Budget", "snippet": "<mark>budget</mark> plan", "rank": 1.0}]}
        )
    )

    context = provider.prefetch("budget", session_id="session-1")

    assert "Budget" in context
    assert "budget plan" in context


@respx.mock
def test_prefetch_empty_on_no_matches(provider):
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(200, json={"items": []}))

    assert provider.prefetch("nothing", session_id="session-1") == ""


@respx.mock
def test_prefetch_empty_on_network_failure(provider):
    respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("boom"))

    assert provider.prefetch("budget", session_id="session-1") == ""


@respx.mock
def test_queue_prefetch_primes_cache_consumed_by_next_prefetch(provider):
    route = respx.get("https://notes.example.com/search").mock(
        side_effect=[
            httpx.Response(200, json={"items": [{"id": "1", "title": "Budget", "snippet": "plan"}]}),
            httpx.Response(200, json={"items": []}),
        ]
    )

    provider.queue_prefetch("budget", session_id="session-1")
    provider._prefetch_thread.join(timeout=2)
    first = provider.prefetch("irrelevant", session_id="session-1")
    second = provider.prefetch("irrelevant", session_id="session-1")

    assert "Budget" in first
    # first prefetch() call returns the primed cache without a second network call;
    # only the second prefetch() call (cache already consumed) triggers a fresh search
    assert route.call_count == 2
    assert second == ""


@respx.mock
def test_queue_prefetch_returns_before_the_network_call_completes(provider):
    release = threading.Event()

    def _slow_response(request):
        release.wait(timeout=2)
        return httpx.Response(200, json={"items": []})

    respx.get("https://notes.example.com/search").mock(side_effect=_slow_response)

    provider.queue_prefetch("budget", session_id="session-1")
    # queue_prefetch must not have blocked on the still-pending response above.
    assert provider._prefetch_thread.is_alive()

    release.set()
    provider._prefetch_thread.join(timeout=2)


@respx.mock
def test_a_stale_prefetch_does_not_clobber_a_newer_one(provider):
    stale_release = threading.Event()

    def _slow_stale_response(request):
        stale_release.wait(timeout=2)
        return httpx.Response(200, json={"items": [{"id": "1", "title": "Stale", "snippet": "old"}]})

    respx.get("https://notes.example.com/search", params={"q": "first"}).mock(side_effect=_slow_stale_response)
    respx.get("https://notes.example.com/search", params={"q": "second"}).mock(
        return_value=httpx.Response(200, json={"items": [{"id": "2", "title": "Fresh", "snippet": "new"}]})
    )

    provider.queue_prefetch("first", session_id="session-1")
    stale_thread = provider._prefetch_thread

    provider.queue_prefetch("second", session_id="session-1")
    provider._prefetch_thread.join(timeout=2)

    # only now let the superseded (first) search finish, after the fresher one already landed
    stale_release.set()
    stale_thread.join(timeout=2)

    result = provider.prefetch("irrelevant", session_id="session-1")

    assert "Fresh" in result
    assert "Stale" not in result


def test_get_tool_schemas_lists_expected_tools(provider):
    names = {schema["name"] for schema in provider.get_tool_schemas()}
    assert names == {"robotnotes_search", "robotnotes_note", "robotnotes_remember", "robotnotes_forget"}


@respx.mock
def test_handle_tool_call_search(provider):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": [{"id": "1", "title": "Budget"}]})
    )

    result = json.loads(provider.handle_tool_call("robotnotes_search", {"query": "budget"}))

    assert result["items"][0]["id"] == "1"


@respx.mock
def test_handle_tool_call_note_not_found_is_tool_error(provider):
    respx.get("https://notes.example.com/notes/missing").mock(return_value=httpx.Response(404))

    result = json.loads(provider.handle_tool_call("robotnotes_note", {"id": "missing"}))

    assert result["error"] == "not_found"


@respx.mock
def test_handle_tool_call_remember_creates_note(provider):
    respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01NEW", "title": "Fact"})
    )

    result = json.loads(
        provider.handle_tool_call("robotnotes_remember", {"title": "Fact", "content": "the sky is blue"})
    )

    assert result["id"] == "01NEW"


@respx.mock
def test_handle_tool_call_forget_deletes_note(provider):
    respx.delete("https://notes.example.com/notes/01NEW").mock(
        return_value=httpx.Response(200, json={"id": "01NEW", "deleted": True})
    )

    result = json.loads(provider.handle_tool_call("robotnotes_forget", {"id": "01NEW"}))

    assert result["deleted"] is True


def test_conversations_path_scoped_by_actor(provider):
    assert provider._conversations_path() == "conversations/hermes-bot"


def test_conversations_path_sanitizes_slashes_in_actor(provider):
    provider._config = RobotNotesConfig.create(base_url="https://notes.example.com", actor="ops/team")
    assert provider._conversations_path() == "conversations/ops_team"


def test_conversations_path_falls_back_to_default_for_dot_segment(provider):
    provider._config = RobotNotesConfig.create(base_url="https://notes.example.com", actor="..")
    assert provider._conversations_path() == "conversations/hermes"


@respx.mock
def test_on_session_end_creates_one_note_first_time(provider):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01SESSION", "title": "session-1", "version": 1})
    )

    provider.on_session_end([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}])

    assert create_route.called
    body = json.loads(create_route.calls.last.request.content)
    assert body["path"] == "conversations/hermes-bot"
    assert body["title"] == "session-1"


@respx.mock
def test_on_session_end_updates_existing_note_for_resumed_session(provider):
    respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(
            200,
            json={
                "items": [
                    {"id": "01SESSION", "title": "session-1", "path": "conversations/hermes-bot", "version": 1}
                ]
            },
        )
    )
    get_route = respx.get("https://notes.example.com/notes/01SESSION")
    create_route = respx.post("https://notes.example.com/notes")
    update_route = respx.put("https://notes.example.com/notes/01SESSION").mock(
        return_value=httpx.Response(200, json={"id": "01SESSION", "version": 2})
    )

    provider.on_session_end([{"role": "user", "content": "more"}])

    assert update_route.called
    assert not create_route.called
    # the note's version already came from the list lookup above — no extra read needed
    assert not get_route.called


@respx.mock
def test_on_memory_write_add_creates_memory_note_first_time(provider):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01MEM", "title": "Memory", "version": 1})
    )

    provider.on_memory_write("add", "memory", "the user prefers dark mode")

    assert create_route.called
    body = json.loads(create_route.calls.last.request.content)
    assert body["title"] == "Memory"
    assert body["path"] == "Hermes"
    assert "dark mode" in body["content"]


@respx.mock
def test_on_memory_write_user_target_uses_separate_note(provider):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01USER", "title": "User", "version": 1})
    )

    provider.on_memory_write("add", "user", "the user's name is Cedric")

    body = json.loads(create_route.calls.last.request.content)
    assert body["title"] == "User"


@respx.mock
def test_on_memory_write_replace_rewrites_existing_note(provider):
    respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "01MEM", "title": "Memory", "path": "Hermes", "version": 3}]}
        )
    )
    update_route = respx.put("https://notes.example.com/notes/01MEM").mock(
        return_value=httpx.Response(200, json={"id": "01MEM", "version": 4})
    )

    provider.on_memory_write("replace", "memory", "new fact")

    body = json.loads(update_route.calls.last.request.content)
    assert body["content"] == "new fact"


@respx.mock
def test_on_memory_write_remove_on_missing_note_is_a_noop(provider):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post("https://notes.example.com/notes")

    provider.on_memory_write("remove", "memory", "")

    assert not create_route.called


def test_get_config_schema_declares_fields():
    schema = RobotNotesProvider().get_config_schema()
    keys = {field["key"] for field in schema}
    assert keys == {"base_url", "actor", "api_key"}
    api_key_field = next(f for f in schema if f["key"] == "api_key")
    assert api_key_field["secret"] is True


def test_save_config_does_not_persist_api_key(tmp_path):
    RobotNotesProvider().save_config(
        {"base_url": "https://notes.example.com", "actor": "hermes-bot", "api_key": "secret-key"}, str(tmp_path)
    )

    saved = json.loads((tmp_path / "robot_notes.json").read_text(encoding="utf-8"))
    assert saved == {"base_url": "https://notes.example.com", "actor": "hermes-bot"}
