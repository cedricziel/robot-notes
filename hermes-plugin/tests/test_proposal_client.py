import httpx
import pytest
import respx

from robot_notes.client import ClientError, RobotNotesClient

BASE = "https://notes.example.com"
PERMISSION = {
    "id": "note",
    "path": "Knowledge",
    "curated": True,
    "approval": "human",
    "policy_revision": 0,
    "policy_fingerprint": "fingerprint",
    "principal_kind": "operator",
    "allowed_actions": ["read", "propose", "edit"],
    "requires_human_approval": True,
}
PROPOSAL = {
    "proposal_id": "proposal",
    "note_id": "note",
    "proposal_revision": 1,
    "record_revision": 1,
    "state": "pending",
    "accepted": False,
}


@pytest.fixture
def client():
    value = RobotNotesClient(base_url=BASE, api_key="test", actor="agent")
    yield value
    value.close()


@respx.mock
def test_permission_lookup_preserves_credential_principal_and_curated_intent(client):
    respx.get(BASE + "/notes/note/permissions").respond(200, json=PERMISSION)
    assert client.get_note_permissions(note_id="note") == PERMISSION
    respx.get(
        BASE + "/notes/permissions", params={"path": "Knowledge", "title": "Draft"}
    ).respond(200, json={**PERMISSION, "id": None})
    assert client.get_note_permissions(path="Knowledge", title="Draft")["id"] is None


@respx.mock
@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        {**PERMISSION, "id": "other"},
        {**PERMISSION, "curated": "true"},
        {**PERMISSION, "policy_revision": True},
        {**PERMISSION, "allowed_actions": ["write"]},
        {**PERMISSION, "requires_human_approval": None},
    ],
)
def test_malformed_permissions_fail_closed(client, body):
    respx.get(BASE + "/notes/note/permissions").respond(200, json=body)
    with pytest.raises(ClientError) as error:
        client.get_note_permissions(note_id="note")
    assert error.value.code == "invalid_response"


@respx.mock
def test_existing_and_new_proposals_send_exact_idempotent_payload(client):
    existing = respx.post(BASE + "/notes/note/proposals").respond(201, json=PROPOSAL)
    operations = [{"type": "delete_note"}]
    assert (
        client.propose_note_update(
            "note",
            base_version=7,
            operations=operations,
            evidence_refs=[],
            idempotency_key="effect",
        )
        == PROPOSAL
    )
    assert (
        existing.calls.last.request.read()
        == httpx.Request(
            "POST",
            BASE,
            json={
                "base_version": 7,
                "operations": operations,
                "evidence_refs": [],
                "idempotency_key": "effect",
            },
        ).read()
    )
    created = respx.post(BASE + "/notes/proposals").respond(201, json=PROPOSAL)
    client.propose_note_create(
        path="Knowledge",
        title="Draft",
        content="claim",
        evidence_refs=[],
        idempotency_key="create",
        curated_intent=True,
    )
    assert b'"curated_intent":true' in created.calls.last.request.read()


@respx.mock
@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        {**PROPOSAL, "note_id": "other"},
        {**PROPOSAL, "accepted": True},
        {**PROPOSAL, "state": "pending", "accepted_version": 2},
        {**PROPOSAL, "state": "accepted", "accepted": True},
        {**PROPOSAL, "proposal_revision": True},
    ],
)
def test_invalid_proposal_acknowledgement_is_not_reported_as_accepted(client, body):
    respx.post(BASE + "/notes/note/proposals").respond(201, json=body)
    with pytest.raises(ClientError) as error:
        client.propose_note_update(
            "note",
            base_version=7,
            operations=[{"type": "delete_note"}],
            evidence_refs=[],
            idempotency_key="effect",
        )
    assert error.value.code == "invalid_response"


@respx.mock
@pytest.mark.parametrize(
    "override", [{"approval": []}, {"principal_kind": {}}, {"allowed_actions": [{}]}]
)
def test_non_scalar_permission_fields_are_client_errors(client, override):
    respx.get(BASE + "/notes/note/permissions").respond(
        200, json={**PERMISSION, **override}
    )
    with pytest.raises(ClientError):
        client.get_note_permissions(note_id="note")


@respx.mock
def test_non_scalar_proposal_state_is_client_error(client):
    respx.post(BASE + "/notes/note/proposals").respond(
        201, json={**PROPOSAL, "state": []}
    )
    with pytest.raises(ClientError):
        client.propose_note_update(
            "note",
            base_version=7,
            operations=[{"type": "delete_note"}],
            evidence_refs=[],
            idempotency_key="effect",
        )


@respx.mock
def test_sdk_always_declares_restrictive_agent_runtime_origin(client):
    route = respx.get(BASE + "/notes/note/permissions").respond(200, json=PERMISSION)
    client.get_note_permissions(note_id="note")
    assert route.calls.last.request.headers["X-Robot-Notes-Agent"] == "true"


@respx.mock
def test_consistent_real_utf16_block_snapshot_is_returned(client):
    import hashlib

    body = "🦾 blue"
    respx.get(BASE + "/notes/note").respond(
        200, json={"id": "note", "version": 1, "content": body}
    )
    respx.get(BASE + "/notes/note/blocks").respond(
        200,
        json={
            "id": "note",
            "version": 1,
            "content_hash": hashlib.sha256(body.encode()).hexdigest(),
            "offset_encoding": "utf-16",
            "blocks": [
                {
                    "id": "b",
                    "revision": 1,
                    "start": 0,
                    "end": 7,
                    "hash": hashlib.sha256(body.encode()).hexdigest(),
                }
            ],
        },
    )
    result = client.get_note_blocks("note")
    assert result["content"] == body
    assert result["blocks"][0]["end"] == 7


@respx.mock
def test_raced_or_malformed_block_snapshot_is_reloaded_then_rejected(client):
    respx.get(BASE + "/notes/note").respond(
        200, json={"id": "note", "version": 1, "content": "old"}
    )
    blocks = respx.get(BASE + "/notes/note/blocks").respond(
        200, json={"id": "note", "version": 2}
    )
    with pytest.raises(ClientError) as error:
        client.get_note_blocks("note")
    assert blocks.call_count == 2
    assert error.value.code == "invalid_response"


@respx.mock
def test_mirror_lookup_skips_newer_descendant_and_finds_exact_folder(client):
    respx.get(BASE + "/notes").mock(
        side_effect=[
            httpx.Response(
                200,
                json={
                    "items": [
                        {
                            "id": "child",
                            "title": "Memory",
                            "path": "Hermes/agents/other",
                            "version": 9,
                        }
                    ]
                },
            ),
            httpx.Response(
                200,
                json={
                    "items": [
                        {
                            "id": "child",
                            "title": "Memory",
                            "path": "Hermes/agents/other",
                            "version": 9,
                        },
                        {
                            "id": "shared",
                            "title": "Memory",
                            "path": "Hermes",
                            "version": 1,
                        },
                    ],
                    "next_cursor": None,
                },
            ),
        ]
    )
    assert client.find_note_by_title("Memory", path="Hermes")["id"] == "shared"


@respx.mock
def test_atomic_block_bundle_uses_its_own_body_and_preserves_provenance(client):
    import hashlib

    bundle = {
        "id": "note",
        "version": 3,
        "content": "body",
        "content_hash": hashlib.sha256(b"body").hexdigest(),
        "offset_encoding": "utf-16",
        "blocks": [
            {
                "id": "b",
                "revision": 1,
                "start": 0,
                "end": 4,
                "hash": hashlib.sha256(b"body").hexdigest(),
            }
        ],
        "provenance": {
            "b": {
                "block_revision": 1,
                "source_unknown": True,
                "evidence_refs": [],
                "supersedes": [],
            }
        },
    }
    respx.get(BASE + "/notes/note/blocks").respond(200, json=bundle)
    old_read = respx.get(BASE + "/notes/note").respond(
        200, json={"id": "note", "version": 2, "content": "old"}
    )
    assert client.get_note_blocks("note") == bundle
    assert not old_read.called
