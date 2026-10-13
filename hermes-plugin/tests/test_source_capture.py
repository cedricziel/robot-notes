import base64
import json
import hashlib

import httpx
import pytest
import respx

from robot_notes import RobotNotesProvider
from robot_notes.source_capture import SourceCapture

BASE = "https://notes.example.com"


@pytest.fixture
def capture_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "fixture-key")
    monkeypatch.setattr(SourceCapture, "start", lambda self: None)
    (tmp_path / "robot_notes.json").write_text(json.dumps({
        "base_url": BASE, "source_capture": True, "source_scope_id": "scope",
    }))
    provider = RobotNotesProvider()
    provider.initialize("session-1", hermes_home=str(tmp_path), agent_context="primary")
    yield provider
    provider.shutdown()


@respx.mock
def test_both_lifecycle_callbacks_deliver_original_messages_as_scoped_sources(capture_provider):
    respx.get(BASE + "/knowledge/capabilities").respond(200, json={
        "knowledge_contract_version": 1, "enabled": True, "source_capture": True,
        "principal_id": "agent:writer", "vault_id": "default",
    })
    def acknowledge(request):
        payload = json.loads(request.content)
        return httpx.Response(200, json={"source": {
            "id": "source", "revision": "revision", "principal_id": "agent:writer", "scope_id": "scope",
            "sha256": hashlib.sha256(base64.b64decode(payload["content_base64"])).hexdigest(),
        }})
    route = respx.post(BASE + "/knowledge/operations/ingest_source").mock(side_effect=acknowledge)
    messages = [{"role": "user", "content": "A😀B"}, {"role": "assistant", "content": "Completed"}]
    capture_provider.sync_turn("A😀B", "Completed", messages=messages, turn_author={"turn_id": "turn-1"})
    respx.get(BASE + "/notes").respond(200, json={"items": []})
    respx.get(BASE + "/notes/permissions").respond(404, json={"error": "not_found"})
    respx.post(BASE + "/notes").respond(201, json={"id": "transcript", "version": 1})
    capture_provider.on_session_end(messages)
    capture_provider._source_capture.flush()
    bodies = [json.loads(call.request.content) for call in route.calls]
    assert [body["observation_kind"] for body in bodies] == ["completed_turn", "session_end"]
    assert bodies[0]["event_id"] == "session-1:turn:turn-1"
    assert all(json.loads(base64.b64decode(body["content_base64"]))["messages"] == messages for body in bodies)
    assert capture_provider.memory_health()["source_capture"]["queue"]["pending"] == 0


@respx.mock
def test_lost_acknowledgement_replays_same_event_and_exact_source_payload(capture_provider):
    respx.get(BASE + "/knowledge/capabilities").respond(200, json={
        "knowledge_contract_version": 1, "enabled": True, "source_capture": True,
        "principal_id": "agent:writer", "vault_id": "default",
    })
    route = respx.post(BASE + "/knowledge/operations/ingest_source")
    attempts = []
    def acknowledge_after_loss(request):
        attempts.append(request)
        if len(attempts) == 1:
            raise httpx.ReadError("lost acknowledgement")
        body = json.loads(request.content)
        return httpx.Response(200, json={"source": {
            "id": "source", "revision": "revision", "principal_id": "agent:writer", "scope_id": "scope",
            "sha256": hashlib.sha256(base64.b64decode(body["content_base64"])).hexdigest(),
        }})
    route.side_effect = acknowledge_after_loss
    capture_provider.sync_turn("Durable fact", "Reply")
    capture_provider._source_capture.flush()
    assert capture_provider._source_capture.outbox.status()["pending"] == 1
    capture_provider._source_capture.flush()
    assert route.calls[0].request.content == route.calls[1].request.content
    assert capture_provider._source_capture.outbox.status()["pending"] == 0


@pytest.mark.parametrize("context", ["subagent", "cron", "flush"])
def test_restricted_contexts_do_not_create_or_enqueue_source_capture(tmp_path, monkeypatch, context):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "fixture-key")
    (tmp_path / "robot_notes.json").write_text(json.dumps({
        "base_url": BASE, "source_capture": True, "source_scope_id": "scope",
    }))
    provider = RobotNotesProvider()
    provider.initialize("session", hermes_home=str(tmp_path), agent_context=context)
    provider.sync_turn("User", "Assistant")
    provider.on_session_end([])
    assert provider._source_capture is None
    assert not (tmp_path / "robot_notes_sources").exists()
    provider.shutdown()


@respx.mock
def test_unsupported_server_blocks_capture_without_ordinary_write_fallback(capture_provider):
    respx.get(BASE + "/knowledge/capabilities").respond(404, json={"error": "not_found"})
    capture_provider.sync_turn("Fact", "Reply")
    capture_provider._source_capture.flush()
    assert capture_provider._source_capture.outbox.status()["blocked"] is True
    assert capture_provider.memory_health()["source_capture"]["state"] == "blocked"


@pytest.mark.parametrize("field,value", [
    ("principal_id", "agent:other"),
    ("scope_id", "other-scope"),
    ("sha256", "0" * 64),
])
@respx.mock
def test_acknowledgement_cannot_change_capture_identity(capture_provider, field, value):
    respx.get(BASE + "/knowledge/capabilities").respond(200, json={
        "knowledge_contract_version": 1, "enabled": True, "source_capture": True,
        "principal_id": "agent:writer", "vault_id": "default",
    })

    def acknowledge(request):
        payload = json.loads(request.content)
        source = {
            "id": "source", "revision": "revision", "principal_id": "agent:writer", "scope_id": "scope",
            "sha256": hashlib.sha256(base64.b64decode(payload["content_base64"])).hexdigest(),
        }
        source[field] = value
        return httpx.Response(200, json={"source": source})

    respx.post(BASE + "/knowledge/operations/ingest_source").mock(side_effect=acknowledge)
    capture_provider.sync_turn("Durable fact", "Reply")
    capture_provider._source_capture.flush()
    assert capture_provider._source_capture.outbox.status()["blocked"] is True
    assert capture_provider.memory_health()["source_capture"]["state"] == "blocked"


@pytest.mark.parametrize("principal,vault", [(None, "default"), ("agent:writer", "other")])
@respx.mock
def test_capability_identity_must_match_selected_vault(capture_provider, principal, vault):
    respx.get(BASE + "/knowledge/capabilities").respond(200, json={
        "knowledge_contract_version": 1, "enabled": True, "source_capture": True,
        "principal_id": principal, "vault_id": vault,
    })
    delivery = respx.post(BASE + "/knowledge/operations/ingest_source")
    capture_provider.sync_turn("Durable fact", "Reply")
    capture_provider._source_capture.flush()
    assert not delivery.called
    assert capture_provider._source_capture.outbox.status()["blocked"] is True
