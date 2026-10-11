import hashlib
import json

import httpx
import pytest
import respx

from robot_notes import RobotNotesProvider
from robot_notes.config import RobotNotesConfig

BASE = 'https://notes.example.com'


@pytest.fixture
def make_provider(tmp_path, monkeypatch):
    monkeypatch.setenv('ROBOT_NOTES_API_KEY', 'key')
    providers = []

    def make(*, enabled=True, context='primary'):
        (tmp_path / 'robot_notes.json').write_text(json.dumps({
            'base_url': BASE, 'evidence_archive': enabled,
            'evidence_retention_days': 7,
        }))
        provider = RobotNotesProvider()
        provider.initialize('session', hermes_home=str(tmp_path), agent_context=context)
        providers.append(provider)
        return provider

    yield make
    for provider in providers:
        provider.shutdown()


def ack(request):
    body = json.loads(request.content)
    return httpx.Response(200, json={
        'id': request.url.path.rsplit('/', 1)[-1],
        'payload': body['payload'], 'expires_at': '2026-10-18T00:00:00.000Z',
    })


@pytest.mark.parametrize('context', ['cron', 'flush', 'subagent'])
def test_non_primary_context_does_not_advertise_checkpoints(make_provider, context):
    provider = make_provider(context=context)
    assert provider.pre_compress_checkpoint_api_version == 1
    provider.sync_turn('hi', 'hello', messages=[{'role': 'tool', 'content': 'result'}])
    assert provider._evidence_outbox is None


def test_disabled_archive_does_not_advertise_checkpoints(make_provider):
    provider = make_provider(enabled=False)
    assert provider.pre_compress_checkpoint_api_version == 1
    assert provider._evidence_outbox is None


@respx.mock
def test_raw_snapshot_preserves_tool_and_non_text_json_and_is_idempotent(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    messages = [{'role': 'tool', 'content': {'full': 'x' * 40000}, 'id': 'uid-1'},
                {'role': 'assistant', 'content': [{'type': 'image_url', 'image_url': {'url': 'https://example.org/a.png'}}]}]
    provider.sync_turn('hi', 'hello', messages=messages)
    provider.on_pre_compress([{'role': 'user', 'content': 'hi'}], require_checkpoint=True)
    first = json.loads(route.calls[0].request.content)['payload']
    provider.sync_turn('hi', 'hello', messages=messages)
    provider.on_pre_compress([{'role': 'user', 'content': 'hi'}], require_checkpoint=True)
    repeated = json.loads(route.calls[2].request.content)['payload']
    assert json.loads(first)['messages'] == messages
    assert first == repeated
    assert route.calls[0].request.url.path == '/evidence/' + hashlib.sha256(first.encode()).hexdigest()


@respx.mock
def test_missing_messages_is_explicit_text_fallback(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    provider.sync_turn('hi', 'hello')
    provider.on_pre_compress([], require_checkpoint=True)
    snapshot = json.loads(json.loads(route.calls[0].request.content)['payload'])
    assert snapshot['capture'] == 'text_fallback'
    assert snapshot['messages'] == [{'role': 'user', 'content': 'hi'}, {'role': 'assistant', 'content': 'hello'}]


@respx.mock
def test_failed_raw_write_survives_restart_before_checkpoint(make_provider):
    first = make_provider()
    failed = respx.put(url__regex=BASE + '/evidence/.*').mock(return_value=httpx.Response(503))
    first.sync_turn('hi', 'hello', messages=[{'role': 'tool', 'content': 'retained tool'}])
    with pytest.raises(RuntimeError, match='evidence'):
        first.on_pre_compress([], require_checkpoint=True)
    first.shutdown()
    resumed = make_provider()
    failed.mock(side_effect=ack)
    resumed.on_pre_compress([{'role': 'user', 'content': 'hi'}], require_checkpoint=True)
    sent = [json.loads(json.loads(call.request.content)['payload']) for call in failed.calls if call.response.status_code == 200]
    assert sent[0]['messages'] == [{'role': 'tool', 'content': 'retained tool'}]
    assert sent[-1]['capture'] == 'host_normalized'
    assert resumed._evidence_outbox.status()['pending'] == 0


@respx.mock
def test_checkpoint_rejects_missing_durable_ack(make_provider):
    provider = make_provider()
    respx.put(url__regex=BASE + '/evidence/.*').mock(return_value=httpx.Response(200, json={}))
    with pytest.raises(RuntimeError, match='evidence'):
        provider.on_pre_compress([], require_checkpoint=True)
    assert provider._evidence_outbox.status()['pending'] == 1


@respx.mock
def test_session_branch_retains_first_lineage_in_pending_snapshot(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    provider.on_session_switch('branch', parent_session_id='session', reset=False, rewound=True)
    provider.sync_turn('hi', 'hello', session_id='branch', messages=[{'role': 'user', 'content': 'branch'}])
    provider.on_pre_compress([], require_checkpoint=True)
    body = json.loads(route.calls[0].request.content)
    assert json.loads(body['payload'])['session_id'] == 'branch'
    assert body['lineage'] == {'parent_session_id': 'session', 'reset': False, 'rewound': True}


@pytest.mark.parametrize('value', [0, 3651, True, 1.5, '7'])
def test_invalid_evidence_retention_is_rejected(value):
    with pytest.raises(ValueError, match='evidence_retention_days'):
        RobotNotesConfig.create(evidence_retention_days=value)


def test_local_capture_failure_stays_fail_closed_across_restart(make_provider, monkeypatch):
    provider = make_provider()
    provider._evidence_outbox.max_bytes = 1
    provider.sync_turn('hi', 'hello', messages=[{'role': 'tool', 'content': 'cannot fit'}])
    with pytest.raises(RuntimeError, match='evidence'):
        provider.on_pre_compress([], require_checkpoint=True)
    provider.shutdown()
    resumed = make_provider()
    with pytest.raises(RuntimeError, match='evidence'):
        resumed.on_pre_compress([], require_checkpoint=True)


def test_expired_pending_evidence_cannot_be_replaced_by_a_text_checkpoint(make_provider):
    provider = make_provider()
    provider._evidence_outbox.clock = lambda: 0
    provider._start_evidence_delivery = lambda: None
    provider.sync_turn('hi', 'hello', messages=[{'role': 'tool', 'content': 'expired'}])
    provider._evidence_outbox.clock = lambda: 8 * 86400
    with pytest.raises(RuntimeError, match='evidence'):
        provider.on_pre_compress([], require_checkpoint=True)
    assert provider._evidence_outbox.status()['expired'] == 1


@respx.mock
def test_delayed_old_session_turn_keeps_original_lineage_after_switch(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    provider.on_session_switch('branch', parent_session_id='session', reset=True)
    provider.sync_turn('old', 'answer', session_id='session', messages=[{'role': 'tool', 'content': 'old turn'}])
    provider.flush_evidence()
    body = json.loads(route.calls[0].request.content)
    assert json.loads(body['payload'])['session_id'] == 'session'
    assert body['lineage'] == {}


@respx.mock
def test_corrected_permanent_error_requires_explicit_retry(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(return_value=httpx.Response(403))
    provider.sync_turn('hi', 'hello')
    with pytest.raises(RuntimeError, match='evidence'):
        provider.flush_evidence()
    route.mock(side_effect=ack)
    provider.flush_evidence(retry_blocked=True)
    assert provider._evidence_outbox.status()['pending'] == 0


@respx.mock
def test_capture_loss_during_checkpoint_delivery_prevents_success(make_provider, monkeypatch):
    provider = make_provider()
    monkeypatch.setattr(provider, '_start_evidence_delivery', lambda: None)

    def acknowledge_and_lose_raw_capture(request):
        provider._evidence_outbox.max_bytes = 1
        provider.sync_turn('new', 'reply', messages=[{'role': 'tool', 'content': 'cannot fit'}])
        return ack(request)

    respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=acknowledge_and_lose_raw_capture)
    with pytest.raises(RuntimeError, match='evidence'):
        provider.on_pre_compress([], require_checkpoint=True)
