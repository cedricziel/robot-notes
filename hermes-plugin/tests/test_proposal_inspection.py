import json

import pytest
import respx

from robot_notes import RobotNotesProvider
from robot_notes.client import ClientError, RobotNotesClient
from robot_notes.config import RobotNotesConfig

BASE = "https://notes.example.com"
SUMMARY = {
    "proposal_id": "proposal",
    "note_id": "note",
    "state": "changes_requested",
    "proposal_revision": 2,
    "record_revision": 3,
    "accepted": False,
    "author_label": "agent display",
    "author_kind": "operator",
    "author_agent_origin": True,
    "created_at": "created",
    "updated_at": "updated",
    "title": "Knowledge",
    "path": "Institutional",
    "new_note": False,
}
DETAIL = {
    **SUMMARY,
    "base_version": 7,
    "operations": [],
    "evidence_refs": [],
    "preview_content": "pending correction",
    "comments": [{"body": "Please cite a source"}],
    "events": [],
    "versions": [],
    "allowed_actions": ["amend", "comment"],
}


@pytest.fixture
def client():
    client = RobotNotesClient(base_url=BASE, api_key="test", actor="display")
    yield client
    client.close()


@respx.mock
def test_list_and_inspect_pending_proposal_are_explicit_reads(client):
    listing = respx.get(
        BASE + "/notes/proposals", params={"include_terminal": "true"}
    ).respond(200, json={"items": [SUMMARY]})
    respx.get(BASE + "/notes/note/proposals/proposal").respond(200, json=DETAIL)
    assert (
        client.list_note_proposals(include_terminal=True)["items"][0]["accepted"]
        is False
    )
    assert (
        client.get_note_proposal("note", "proposal")["preview_content"]
        == "pending correction"
    )
    assert listing.calls.last.request.headers["X-Robot-Notes-Agent"] == "true"


@respx.mock
@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        {"items": None},
        {"items": [{**SUMMARY, "accepted": True}]},
        {"items": [{**SUMMARY, "author_agent_origin": "false"}]},
    ],
)
def test_malformed_proposal_list_is_rejected_as_a_whole(client, body):
    respx.get(BASE + "/notes/proposals").respond(200, json=body)
    with pytest.raises(ClientError):
        client.list_note_proposals()


@respx.mock
@pytest.mark.parametrize(
    "override",
    [
        {"proposal_id": "other"},
        {"note_id": "other"},
        {"preview_content": {}},
        {"comments": None},
    ],
)
def test_malformed_or_wrong_target_proposal_detail_is_rejected(client, override):
    respx.get(BASE + "/notes/note/proposals/proposal").respond(
        200, json={**DETAIL, **override}
    )
    with pytest.raises(ClientError):
        client.get_note_proposal("note", "proposal")


@respx.mock
@pytest.mark.parametrize("context", ["primary", "cron", "flush", "subagent"])
def test_native_proposal_inspection_stays_readonly_in_every_context(
    tmp_path, monkeypatch, context
):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "test")
    RobotNotesConfig.create(base_url=BASE).save(str(tmp_path))
    respx.get(BASE + "/notes/proposals").respond(200, json={"items": [SUMMARY]})
    respx.get(BASE + "/notes/note/proposals/proposal").respond(200, json=DETAIL)
    provider = RobotNotesProvider()
    provider.initialize("session", hermes_home=str(tmp_path), agent_context=context)
    try:
        assert (
            json.loads(provider.handle_tool_call("robotnotes_proposals", {}))["items"][
                0
            ]["state"]
            == "changes_requested"
        )
        assert (
            json.loads(
                provider.handle_tool_call(
                    "robotnotes_proposal",
                    {"note_id": "note", "proposal_id": "proposal"},
                )
            )["accepted"]
            is False
        )
        assert "robotnotes_approve_proposal" not in {
            tool["name"] for tool in provider.get_tool_schemas()
        }
    finally:
        provider.shutdown()


def test_native_disabled_hides_and_blocks_proposal_inspection():
    provider = RobotNotesProvider()
    provider._config = RobotNotesConfig.create(native_tools=False)
    assert provider.get_tool_schemas() == []
    assert (
        json.loads(provider.handle_tool_call("robotnotes_proposals", {}))["code"]
        == "tools_disabled"
    )


@respx.mock
@pytest.mark.parametrize(
    "identifier", ["", "../other", "x?path=other", "x%2fy", "x\\y", "x\n"]
)
def test_untrusted_proposal_coordinates_never_splice_request_routes(client, identifier):
    with pytest.raises(ClientError) as error:
        client.get_note_proposal("note", identifier)
    assert error.value.code == "invalid_arguments"
    assert not respx.calls
