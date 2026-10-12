import pytest

pytest.importorskip("agent.memory_manager")

from agent.memory_manager import MemoryManager
from agent.memory_provider import MemoryProvider


class Recorder(MemoryProvider):
    def __init__(self):
        self.writes = []

    @property
    def name(self):
        return "recorder"

    def is_available(self):
        return True

    def initialize(self, session_id, **kwargs):
        pass

    def get_tool_schemas(self):
        return []

    def on_memory_write(self, action, target, content, metadata=None):
        self.writes.append((action, target, content, metadata))


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    manager = MemoryManager()
    recorder = Recorder()
    manager.add_provider(recorder)
    yield manager, recorder
    manager.shutdown_all()


def test_committed_exact_entry_overrides_a_partial_selector_and_forged_metadata(bridge):
    manager, recorder = bridge
    manager.notify_memory_tool_write(
        {"success": True, "replaced_entry": "profile:\ncolor blue"},
        {
            "action": "replace",
            "target": "user",
            "old_text": "color",
            "content": "color red",
        },
        build_metadata=lambda: {"session_id": "session", "previous_content": "forged"},
    )
    assert recorder.writes == [
        (
            "replace",
            "user",
            "color red",
            {
                "session_id": "session",
                "old_text": "color",
                "previous_content": "profile:\ncolor blue",
            },
        )
    ]


def test_batch_corrections_use_committed_entry_at_each_operation_index(bridge):
    manager, recorder = bridge
    manager.notify_memory_tool_write(
        {
            "success": True,
            "replaced_entries": {"1": "color blue"},
            "removed_entries": {"2": "size small"},
        },
        {
            "target": "memory",
            "operations": [
                {"action": "replace", "old_text": "color", "content": "color red"},
                {"action": "remove", "old_text": "size"},
            ],
        },
        build_metadata=lambda: {"tool_call_id": "tool-call"},
    )
    assert recorder.writes == [
        (
            "replace",
            "memory",
            "color red",
            {
                "tool_call_id": "tool-call",
                "old_text": "color",
                "previous_content": "color blue",
            },
        ),
        (
            "remove",
            "memory",
            "",
            {
                "tool_call_id": "tool-call",
                "old_text": "size",
                "previous_content": "size small",
            },
        ),
    ]


def test_missing_committed_previous_entry_does_not_promote_a_selector_to_exact_evidence(
    bridge,
):
    manager, recorder = bridge
    manager.notify_memory_tool_write(
        {"success": True},
        {"action": "replace", "old_text": "color", "content": "color red"},
        build_metadata=lambda: {"previous_content": "forged"},
    )
    assert recorder.writes[0][3] == {"old_text": "color"}


def test_failed_or_staged_tool_result_never_emits_a_correction(bridge):
    manager, recorder = bridge
    manager.notify_memory_tool_write(
        {"success": True, "staged": True},
        {"action": "replace", "old_text": "color", "content": "color red"},
    )
    assert recorder.writes == []
