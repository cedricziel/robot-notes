import pytest

from robot_notes.client import ClientError
from robot_notes.curated_writes import prepare_write, deliver_write
from robot_notes.outbox import Outbox
from test_correction_proposals import accepted


class Client:
    def __init__(self, *, curated=True, unavailable=False):
        self.curated = curated
        self.unavailable = unavailable
        self.submissions = []
        self.note, self.mapping = accepted("old", [(0, 3)])
        self.note.update(title="Memory", path="Knowledge")

    def get_note_permissions(self, **kwargs):
        if self.unavailable:
            raise ClientError("unsupported", status=404)
        return {
            "curated": self.curated,
            "allowed_actions": ["propose", "edit"],
            "principal_kind": "operator",
        }

    def get_note_blocks(self, note_id):
        return {**self.mapping, "content": self.note["content"]}

    def get_note(self, note_id):
        return dict(self.note)

    def propose_note_update(self, note_id, **kwargs):
        self.submissions.append((note_id, kwargs))
        return {
            "proposal_id": "p",
            "note_id": note_id,
            "state": "pending",
            "accepted": False,
        }

    def propose_note_create(self, **kwargs):
        self.submissions.append(("new", kwargs))
        return {
            "proposal_id": "p",
            "note_id": "new",
            "state": "pending",
            "accepted": False,
        }

    def update_note(self, note_id, **kwargs):
        self.note["content"] = kwargs["content"]
        return self.note


def test_curated_operator_key_always_freezes_a_manual_proposal():
    client = Client()
    prepared = prepare_write(
        client,
        current=client.note,
        title="Memory",
        path="Knowledge",
        desired="new",
        refs=[{"kind": "unknown", "reason": "source_not_recorded"}],
    )
    assert prepared["route"] == "proposal"
    first = deliver_write(client, prepared)
    second = deliver_write(client, prepared)
    assert first["accepted"] is False
    assert second["state"] == "pending"
    assert client.note["content"] == "old"
    assert client.submissions[0] == client.submissions[1]


def test_curated_creation_is_a_draft_without_accepted_placeholder():
    client = Client()
    prepared = prepare_write(
        client, current=None, title="Draft", path="Knowledge", desired="claim", refs=[]
    )
    assert prepared["route"] == "proposal_create"
    assert deliver_write(client, prepared)["accepted"] is False
    assert client.submissions[0][1]["curated_intent"] is True


def test_explicit_institutional_intent_uses_proposal_even_in_ordinary_folder():
    client = Client(curated=False)
    prepared = prepare_write(
        client,
        current=None,
        title="Draft",
        path="Personal",
        desired="claim",
        refs=[],
        curated_intent=True,
    )
    assert prepared["route"] == "proposal_create"


def test_unsupported_permission_api_fails_closed_for_explicit_or_observed_curated_target():
    client = Client(unavailable=True)
    with pytest.raises(ClientError):
        prepare_write(
            client,
            current=None,
            title="Draft",
            path="Knowledge",
            desired="claim",
            refs=[],
            curated_intent=True,
        )
    with pytest.raises(ClientError):
        prepare_write(
            client,
            current={**client.note, "properties": {"curated": "true"}},
            title="Memory",
            path="Knowledge",
            desired="new",
            refs=[],
        )


def test_ordinary_personal_legacy_prepared_effect_retains_ack_idempotence():
    client = Client(curated=False, unavailable=True)
    prepared = prepare_write(
        client,
        current=client.note,
        title="Memory",
        path="Personal",
        desired="new",
        refs=[],
    )
    assert prepared["route"] == "accepted"
    deliver_write(client, prepared)
    deliver_write(client, prepared)
    assert client.note["content"] == "new"


def test_ordinary_personal_lineage_is_explicitly_unknown_and_not_persisted_in_properties():
    client = Client(curated=False)
    refs = [{"kind": "conversation", "session_id": "real-session"}]
    prepared = prepare_write(
        client,
        current=client.note,
        title="Memory",
        path="Personal",
        desired="new",
        refs=refs,
    )
    result = deliver_write(client, prepared)
    assert result["source_unknown"] is True
    assert "properties" not in client.note
    assert not client.submissions


def test_frozen_ordinary_effect_blocks_after_curated_designation_change():
    client = Client(curated=False)
    prepared = prepare_write(
        client,
        current=client.note,
        title="Memory",
        path="Personal",
        desired="new",
        refs=[],
    )
    client.curated = True
    with pytest.raises(ClientError) as error:
        deliver_write(client, prepared)
    assert error.value.code == "curated_policy_changed"
    assert client.note["content"] == "old"
    assert not client.submissions


@pytest.mark.parametrize("existing", [False, True])
def test_identical_independent_proposals_use_distinct_retry_keys(existing):
    client = Client()
    arguments = {
        "current": client.note if existing else None,
        "title": "Memory",
        "path": "Knowledge",
        "desired": "new",
        "refs": [],
    }
    first = prepare_write(client, **arguments)
    second = prepare_write(client, **arguments)

    deliver_write(client, first)
    deliver_write(client, second)

    assert (
        client.submissions[0][1]["idempotency_key"]
        != client.submissions[1][1]["idempotency_key"]
    )


def test_explicit_retry_key_survives_preparation_and_delivery():
    client = Client()
    prepared = prepare_write(
        client,
        current=None,
        title="Memory",
        path="Knowledge",
        desired="new",
        refs=[],
        idempotency_key="caller-operation",
    )

    deliver_write(client, prepared)
    deliver_write(client, prepared)

    assert client.submissions[0][1]["idempotency_key"] == "caller-operation"
    assert client.submissions[1] == client.submissions[0]


def test_queued_proposal_retry_preserves_generated_key_after_restart(tmp_path):
    client = Client()
    path = tmp_path / "outbox.sqlite"
    queue = Outbox(path)
    queue.enqueue({"content": "new"})

    def prepare(operation):
        return {
            **operation,
            "prepared": prepare_write(
                client,
                current=None,
                title="Memory",
                path="Knowledge",
                desired=operation["content"],
                refs=[],
            ),
        }

    def lose_ack(operation):
        deliver_write(client, operation["prepared"])
        raise OSError("lost acknowledgement")

    assert queue.deliver_one(lose_ack, prepare=prepare) is False
    resumed = Outbox(path)
    assert resumed.deliver_one(
        lambda operation: deliver_write(client, operation["prepared"]),
        prepare=lambda operation: pytest.fail("Prepared proposal was not persisted"),
    )
    assert client.submissions[1] == client.submissions[0]


@pytest.mark.parametrize("changed", [{"title": "Moved"}, {"path": "OtherIdentity"}])
def test_equal_body_creation_ack_is_rejected_after_lookup_target_moves(changed):
    client = Client(curated=False, unavailable=True)
    prepared = prepare_write(
        client, current=None, title="Memory", path="Hermes", desired="desired", refs=[]
    )
    client.find_note_by_title = lambda title, path: {
        "id": "note",
        "title": "Memory",
        "path": "Hermes",
    }
    client.note.update(
        {"title": "Memory", "path": "Hermes", "content": "desired", **changed}
    )
    with pytest.raises(ClientError) as error:
        deliver_write(client, prepared)
    assert error.value.path_conflict
