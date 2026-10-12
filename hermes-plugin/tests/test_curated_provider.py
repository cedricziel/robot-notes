import json

from robot_notes import RobotNotesProvider
from robot_notes.config import RobotNotesConfig
from test_curated_write_planning import Client


def provider_with(client):
    provider = RobotNotesProvider()
    provider._config = RobotNotesConfig.create(
        base_url="https://notes.example.com", api_key="test"
    )
    provider._client = client
    client.note["path"] = "Hermes"
    client.find_note_by_title = lambda title, path: dict(client.note)
    return provider


def test_immediate_multiline_correction_proposes_exact_committed_entry_with_lineage():
    client = Client()
    provider = provider_with(client)
    provider.on_memory_write(
        "replace",
        "memory",
        "new",
        {
            "old_text": "ambiguous",
            "previous_content": "old",
            "session_id": "actual-host-session",
            "tool_call_id": "call",
        },
    )
    assert client.note["content"] == "old"
    assert client.submissions[0][1]["operations"][0]["text"] == "new"
    assert client.submissions[0][1]["evidence_refs"] == [
        {
            "kind": "conversation",
            "session_id": "actual-host-session",
            "tool_call_id": "call",
        }
    ]
    assert provider.memory_health()["mirror"]["state"] == "pending_review"


def test_durable_preparation_freezes_a_proposal_and_same_key_for_replay():
    client = Client()
    provider = provider_with(client)
    operation = {
        "kind": "mirror",
        "note": {"title": "Memory", "path": "Hermes"},
        "action": "replace",
        "content": "new",
        "metadata": {"previous_content": "old"},
    }
    prepared = provider._prepare_automatic(operation)
    assert prepared["prepared"]["route"] == "proposal"
    provider._deliver_automatic(prepared)
    provider._deliver_automatic(prepared)
    assert client.submissions[0] == client.submissions[1]
    assert client.note["content"] == "old"


def test_ambiguous_immediate_correction_does_not_append_active_claim():
    client = Client(curated=False)
    client.note["content"] = "old blue\nold green"
    provider = provider_with(client)
    provider.on_memory_write("replace", "memory", "new", {"old_text": "old"})
    assert client.note["content"] == "old blue\nold green"
    assert provider.memory_health()["mirror"]["state"] == "needs_review"


def test_native_curated_forget_is_pending_whole_note_proposal():
    client = Client()
    provider = provider_with(client)
    result = json.loads(provider.handle_tool_call("robotnotes_forget", {"id": "note"}))
    assert result["accepted"] is False
    assert result["proposal_id"] == "p"
    assert client.submissions[0][1]["operations"] == [{"type": "delete_note"}]


def test_destination_move_between_lookup_and_read_does_not_edit_other_scope():
    client = Client(curated=False)
    provider = provider_with(client)
    client.note["path"] = "Other/Identity"
    provider.on_memory_write("replace", "memory", "new", {"previous_content": "old"})
    assert client.note["content"] == "old"
    assert not client.submissions
    assert provider.memory_health()["mirror"]["state"] == "failed"


def test_replayed_denied_proposal_is_not_reported_as_pending_or_accepted():
    client = Client()
    provider = provider_with(client)
    client.propose_note_update = lambda note_id, **kwargs: {
        "proposal_id": "existing",
        "note_id": note_id,
        "state": "denied",
        "accepted": False,
    }
    provider.on_memory_write("replace", "memory", "new", {"previous_content": "old"})
    assert provider.memory_health()["mirror"]["state"] == "denied"
    assert client.note["content"] == "old"


def test_legacy_no_id_creation_move_does_not_drain_the_original_queue(tmp_path):
    from robot_notes.client import ClientError
    from robot_notes.outbox import Outbox

    client = Client(curated=False, unavailable=True)
    provider = provider_with(client)
    client.find_note_by_title = lambda title, path: {
        "id": "note",
        "title": "Memory",
        "path": "Hermes",
    }
    client.note.update(title="Moved", path="OtherIdentity", content="desired")
    operation = {
        "kind": "mirror",
        "action": "add",
        "content": "desired",
        "metadata": {},
        "prepared": {"title": "Memory", "path": "Hermes", "content": "desired"},
    }
    queue = Outbox(tmp_path / "queue.sqlite")
    queue.enqueue(operation)
    errors = []

    def classify(error):
        errors.append(error)
        return "path_conflict", False

    assert (
        queue.deliver_one(
            provider._deliver_automatic,
            classify,
            provider._prepare_automatic,
            provider._upgrade_automatic,
        )
        is False
    )
    assert isinstance(errors[0], ClientError)
    assert errors[0].path_conflict
    assert queue.status()["pending"] == 1
    assert queue.status()["blocked"] is True
