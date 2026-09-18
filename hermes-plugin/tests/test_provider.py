import json
import threading

import httpx
import pytest
import respx

import robot_notes
from robot_notes import SKILL_NAME, SKILL_PATH, RobotNotesConfig, RobotNotesProvider, register


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
def test_queue_prefetch_spawns_via_spawn_context_thread(provider, monkeypatch):
    """Background work must go through the host's spawn_context_thread (never a bare
    threading.Thread) so contextvars -- profile home, the per-turn secret scope -- propagate;
    proven here by monkeypatching the compat function and asserting it was the one called."""
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(200, json={"items": []}))
    captured = {}
    real_spawn_context_thread = robot_notes.spawn_context_thread

    def fake_spawn_context_thread(target, *, name, **kwargs):
        captured["name"] = name
        captured["called"] = True
        return real_spawn_context_thread(target, name=name, **kwargs)

    monkeypatch.setattr(robot_notes, "spawn_context_thread", fake_spawn_context_thread)

    provider.queue_prefetch("budget", session_id="session-1")
    provider._prefetch_thread.join(timeout=2)

    assert captured == {"name": "robot-notes-prefetch", "called": True}


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
    assert names == {
        "robotnotes_search",
        "robotnotes_list",
        "robotnotes_note",
        "robotnotes_remember",
        "robotnotes_forget",
    }


@respx.mock
def test_handle_tool_call_search(provider):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": [{"id": "1", "title": "Budget"}]})
    )

    result = json.loads(provider.handle_tool_call("robotnotes_search", {"query": "budget"}))

    assert result["items"][0]["id"] == "1"


@respx.mock
def test_handle_tool_call_list(provider):
    route = respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "1", "title": "Budget"}], "next_cursor": None}
        )
    )

    result = json.loads(provider.handle_tool_call("robotnotes_list", {}))

    assert route.called
    assert result["items"][0]["id"] == "1"
    assert result["next_cursor"] is None


@respx.mock
def test_handle_tool_call_list_forwards_path_and_after(provider):
    route = respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(200, json={"items": [], "next_cursor": None})
    )

    provider.handle_tool_call("robotnotes_list", {"path": "Hermes", "after": "01CURSOR", "limit": 10})

    sent = route.calls.last.request
    assert sent.url.params["path"] == "Hermes"
    assert sent.url.params["after"] == "01CURSOR"
    assert sent.url.params["limit"] == "10"


@respx.mock
def test_handle_tool_call_note_not_found_is_tool_error(provider):
    respx.get("https://notes.example.com/notes/missing").mock(return_value=httpx.Response(404))

    result = json.loads(provider.handle_tool_call("robotnotes_note", {"id": "missing"}))

    # tool_error's shape: "error" carries the human-readable message, structured fields
    # (here "code") ride alongside it rather than overloading "error" with a category name.
    assert result["code"] == "not_found"
    assert "error" in result


def test_handle_tool_call_unavailable_is_tool_error():
    provider = RobotNotesProvider()  # never initialize()'d, so there is no client

    result = json.loads(provider.handle_tool_call("robotnotes_search", {"query": "budget"}))

    assert result["code"] == "unavailable"
    assert "error" in result


def test_handle_tool_call_unknown_tool_is_tool_error(provider):
    result = json.loads(provider.handle_tool_call("not_a_real_tool", {}))

    assert result["code"] == "unknown_tool"
    assert "error" in result


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
def test_on_session_switch_rebinds_session_id_so_on_session_end_targets_a_new_note(provider):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01SESSION", "title": "session-1", "version": 1})
    )

    provider.on_session_end([{"role": "user", "content": "first"}])
    provider.on_session_switch("session-2")
    provider.on_session_end([{"role": "user", "content": "second"}])

    titles = [json.loads(call.request.content)["title"] for call in create_route.calls]
    assert titles == ["session-1", "session-2"]


def test_on_session_switch_ignores_empty_new_session_id(provider):
    provider.on_session_switch("")

    assert provider._session_id == "session-1"


def test_on_session_switch_ignores_blank_new_session_id(provider):
    provider.on_session_switch("   ")

    assert provider._session_id == "session-1"


@respx.mock
def test_on_session_switch_discards_a_prefetch_queued_before_it(provider):
    release = threading.Event()

    def _slow_response(request):
        release.wait(timeout=2)
        return httpx.Response(
            200, json={"items": [{"id": "1", "title": "Stale", "snippet": "from the old session"}]}
        )

    respx.get("https://notes.example.com/search").mock(side_effect=_slow_response)

    provider.queue_prefetch("old query", session_id="session-1")
    stale_thread = provider._prefetch_thread

    provider.on_session_switch("session-2")

    # let the superseded search land after the switch has already moved the generation on
    release.set()
    stale_thread.join(timeout=2)

    # the stale result must not have been allowed to populate the cache for the new session
    assert provider._prefetch_cache == ""


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


@pytest.fixture
def subagent_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize("session-1", hermes_home=str(tmp_path), agent_context="subagent")
    return p


@pytest.fixture
def cron_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize("session-1", hermes_home=str(tmp_path), agent_context="cron")
    return p


def test_initialize_defaults_write_enabled_when_agent_context_missing(provider):
    assert provider._can_write() is True


@pytest.mark.parametrize("agent_context", ["subagent", "cron", "flush"])
def test_initialize_disables_writes_for_non_primary_contexts(tmp_path, monkeypatch, agent_context):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize("session-1", hermes_home=str(tmp_path), agent_context=agent_context)

    assert p._can_write() is False


def test_initialize_enables_writes_for_primary_context(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize("session-1", hermes_home=str(tmp_path), agent_context="primary")

    assert p._can_write() is True


def test_initialize_records_hermes_home_platform_and_agent_identity(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}), encoding="utf-8"
    )
    p = RobotNotesProvider()
    p.initialize(
        "session-1",
        hermes_home=str(tmp_path),
        platform="cli",
        agent_identity="research-bot",
    )

    assert p._hermes_home == str(tmp_path)
    assert p._platform == "cli"
    assert p._agent_identity == "research-bot"


@respx.mock
@pytest.mark.parametrize("ctx_provider", ["subagent_provider", "cron_provider"])
def test_on_session_end_skipped_for_non_primary_context(request, ctx_provider):
    create_route = respx.post("https://notes.example.com/notes")
    provider = request.getfixturevalue(ctx_provider)

    provider.on_session_end([{"role": "user", "content": "hi"}])

    assert not create_route.called


@respx.mock
@pytest.mark.parametrize("ctx_provider", ["subagent_provider", "cron_provider"])
def test_on_memory_write_skipped_for_non_primary_context(request, ctx_provider):
    create_route = respx.post("https://notes.example.com/notes")
    provider = request.getfixturevalue(ctx_provider)

    provider.on_memory_write("add", "memory", "the user prefers dark mode")

    assert not create_route.called


@pytest.mark.parametrize("ctx_provider", ["subagent_provider", "cron_provider"])
def test_handle_tool_call_remember_gated_for_non_primary_context(request, ctx_provider):
    provider = request.getfixturevalue(ctx_provider)

    result = json.loads(provider.handle_tool_call("robotnotes_remember", {"title": "Fact", "content": "x"}))

    assert result["code"] == "read_only"


@pytest.mark.parametrize("ctx_provider", ["subagent_provider", "cron_provider"])
def test_handle_tool_call_forget_gated_for_non_primary_context(request, ctx_provider):
    provider = request.getfixturevalue(ctx_provider)

    result = json.loads(provider.handle_tool_call("robotnotes_forget", {"id": "01NEW"}))

    assert result["code"] == "read_only"


@respx.mock
def test_handle_tool_call_search_still_works_for_subagent_context(subagent_provider):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": [{"id": "1", "title": "Budget"}]})
    )

    result = json.loads(subagent_provider.handle_tool_call("robotnotes_search", {"query": "budget"}))

    assert result["items"][0]["id"] == "1"


@respx.mock
def test_prefetch_still_works_for_subagent_context(subagent_provider):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "1", "title": "Budget", "snippet": "budget plan"}]}
        )
    )

    assert "Budget" in subagent_provider.prefetch("budget", session_id="session-1")


def test_save_config_does_not_persist_api_key(tmp_path):
    RobotNotesProvider().save_config(
        {"base_url": "https://notes.example.com", "actor": "hermes-bot", "api_key": "secret-key"}, str(tmp_path)
    )

    saved = json.loads((tmp_path / "robot_notes.json").read_text(encoding="utf-8"))
    assert saved == {"base_url": "https://notes.example.com", "actor": "hermes-bot"}


class _FakeCtxWithSkills:
    def __init__(self):
        self.provider = None
        self.skills = []

    def register_memory_provider(self, provider):
        self.provider = provider

    def register_skill(self, name, path, description=""):
        self.skills.append((name, path, description))


class _FakeCtxWithoutSkills:
    """No register_skill attribute at all, like an older Hermes host."""

    def __init__(self):
        self.provider = None

    def register_memory_provider(self, provider):
        self.provider = provider


def test_register_registers_provider_and_skill_when_ctx_supports_it():
    ctx = _FakeCtxWithSkills()

    register(ctx)

    assert isinstance(ctx.provider, RobotNotesProvider)
    assert len(ctx.skills) == 1
    name, path, description = ctx.skills[0]
    assert name == SKILL_NAME
    assert path == SKILL_PATH
    assert description


def test_register_skill_path_points_at_a_shipped_skill_md():
    assert SKILL_PATH.name == "SKILL.md"
    assert SKILL_PATH.is_file()


def test_register_registers_provider_only_when_ctx_lacks_register_skill():
    ctx = _FakeCtxWithoutSkills()

    register(ctx)

    assert isinstance(ctx.provider, RobotNotesProvider)
    assert not hasattr(ctx, "register_skill")
