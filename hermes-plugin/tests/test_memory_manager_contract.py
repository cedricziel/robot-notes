"""Contract test: drives ``RobotNotesProvider`` through the REAL
``agent.memory_manager.MemoryManager`` from a hermes-agent checkout, rather than calling
the provider directly (as ``tests/test_provider.py`` does) -- this exercises the actual
fan-out / dispatch / initialize plumbing a live Hermes process uses. Skipped unless
``agent.memory_manager`` imports. The docs point at hermes-agent's own
``tests/agent/test_memory_provider.py`` for the upstream patterns this mirrors.

To run:

    git clone --depth 1 https://github.com/NousResearch/hermes-agent /tmp/hermes-agent
    cd hermes-plugin
    PYTHONPATH=/tmp/hermes-agent .venv/bin/python -m pytest tests/test_memory_manager_contract.py -v

Import cost, checked against a real clone: ``agent.memory_manager`` additionally pulls in
``agent.skill_commands`` (-> ``hermes_constants``, ``agent.prompt_cache_boundary``,
``agent.skill_preprocessing`` -> ``hermes_cli._subprocess_compat``), ``tools.hook_output_spill``
(-> ``tools.tool_output_limits`` -> ``hermes_constants``) and ``tools.registry``, on top of
``agent.memory_provider`` itself (see ``test_stub_parity.py``'s docstring for that one).
Every one of those, transitively, is standard-library only -- so, like
``agent.memory_provider`` alone, a bare ``PYTHONPATH`` pointing at the checkout root is
enough to run *this* test too: no ``pip install`` of hermes-agent's own dependencies, and
no ``pip install -e`` of the checkout itself, is required. ``MemoryManager.add_provider``
does do one more lazy import at call time (``from toolsets import _HERMES_CORE_TOOLS``),
also standard-library only.
"""

from __future__ import annotations

import json

import httpx
import pytest
import respx

pytest.importorskip("agent.memory_manager")

from agent.memory_manager import MemoryManager  # noqa: E402

from robot_notes import RobotNotesProvider  # noqa: E402

BASE_URL = "https://notes.example.com"


@pytest.fixture
def manager_and_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": BASE_URL, "actor": "hermes-bot"}), encoding="utf-8"
    )
    manager = MemoryManager()
    provider = RobotNotesProvider()
    manager.add_provider(provider)
    manager.initialize_all(
        session_id="session-1", hermes_home=str(tmp_path), platform="cli", agent_context="primary"
    )
    yield manager, provider
    manager.shutdown_all()


def test_add_provider_registers_it(manager_and_provider):
    manager, _ = manager_and_provider
    assert manager.get_provider("robot_notes") is not None


def test_initialize_all_configures_the_provider(manager_and_provider):
    _, provider = manager_and_provider
    assert provider.is_available() is True


@respx.mock
def test_prefetch_all_returns_provider_context(manager_and_provider):
    manager, _ = manager_and_provider
    respx.get(f"{BASE_URL}/search").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "1", "title": "Budget", "snippet": "<mark>budget</mark> plan"}]}
        )
    )

    context = manager.prefetch_all("budget", session_id="session-1")

    assert "Budget" in context


@respx.mock
def test_handle_tool_call_routes_through_the_manager(manager_and_provider):
    manager, _ = manager_and_provider
    respx.get(f"{BASE_URL}/search").mock(
        return_value=httpx.Response(200, json={"items": [{"id": "1", "title": "Budget"}]})
    )

    result = json.loads(manager.handle_tool_call("robotnotes_search", {"query": "budget"}))

    assert result["items"][0]["id"] == "1"


def test_handle_tool_call_unknown_tool_is_a_tool_error(manager_and_provider):
    manager, _ = manager_and_provider

    result = json.loads(manager.handle_tool_call("not_a_real_tool", {}))

    assert "error" in result


@respx.mock
def test_on_memory_write_mirrors_to_the_provider(manager_and_provider):
    manager, _ = manager_and_provider
    respx.get(f"{BASE_URL}/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post(f"{BASE_URL}/notes").mock(
        return_value=httpx.Response(201, json={"id": "01MEM", "title": "Memory", "version": 1})
    )

    manager.on_memory_write("add", "memory", "the user prefers dark mode")

    assert create_route.called
    body = json.loads(create_route.calls.last.request.content)
    assert "dark mode" in body["content"]


@respx.mock
def test_on_session_end_writes_a_summary_note(manager_and_provider):
    manager, _ = manager_and_provider
    respx.get(f"{BASE_URL}/notes").mock(return_value=httpx.Response(200, json={"items": []}))
    create_route = respx.post(f"{BASE_URL}/notes").mock(
        return_value=httpx.Response(201, json={"id": "01SESSION", "title": "session-1", "version": 1})
    )

    manager.on_session_end([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}])

    assert create_route.called
    body = json.loads(create_route.calls.last.request.content)
    assert body["path"] == "conversations/hermes-bot"
    assert body["title"] == "session-1"


def test_shutdown_all_is_safe_to_call_twice(manager_and_provider):
    """The fixture itself calls ``shutdown_all()`` again on teardown; closing the
    provider's already-closed HTTP client a second time must not raise."""
    manager, _ = manager_and_provider
    manager.shutdown_all()
