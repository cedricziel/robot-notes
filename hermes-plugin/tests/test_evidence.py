from dataclasses import asdict
from types import SimpleNamespace

import hashlib
import json

import httpx
import pytest
import respx

from robot_notes import RobotNotesProvider
from robot_notes.config import RobotNotesConfig
from robot_notes.evidence import EvidenceArchive

BASE = 'https://notes.example.com'


@pytest.fixture
def make_provider(tmp_path, monkeypatch):
    monkeypatch.setenv('ROBOT_NOTES_API_KEY', 'key')
    providers = []

    def make(*, enabled=True, context='primary', native_tools=True):
        (tmp_path / 'robot_notes.json').write_text(json.dumps({
            'base_url': BASE, 'evidence_archive': enabled,
            'evidence_retention_days': 7, 'native_tools': native_tools,
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


def test_repeated_pending_snapshot_does_not_consume_queue_capacity(make_provider, monkeypatch):
    provider = make_provider()
    monkeypatch.setattr(provider, '_start_evidence_delivery', lambda: None)
    provider._evidence_outbox.max_operations = 1
    messages = [{'role': 'tool', 'content': 'same completed turn', 'id': 'stable-uid'}]
    provider.sync_turn('hi', 'hello', messages=messages)
    provider.sync_turn('hi', 'hello', messages=messages)
    assert provider._evidence_outbox.status()['pending'] == 1
    assert provider._evidence_capture_error is False


def test_default_scope_fields_preserve_pending_legacy_evidence_queue(make_provider, monkeypatch, tmp_path):
    provider = make_provider()
    monkeypatch.setattr(provider, '_start_evidence_delivery', lambda: None)
    provider.sync_turn('hi', 'hello', messages=[{'role': 'tool', 'content': 'pending before scope fields'}])
    configured = SimpleNamespace(**{
        **asdict(provider._config), 'memory_scope': 'shared', 'user_id': '', 'agent_id': '',
    })
    resumed = EvidenceArchive(configured, tmp_path)
    assert resumed.outbox.status()['pending'] == 1


def test_identity_scope_cannot_replay_another_identities_pending_evidence(make_provider, monkeypatch, tmp_path):
    provider = make_provider()
    first_config = SimpleNamespace(**{
        **asdict(provider._config), 'memory_scope': 'identity', 'user_id': 'alice', 'agent_id': 'planner',
    })
    first = EvidenceArchive(first_config, tmp_path)
    first.enqueue('session', 'turn', [{'role': 'tool', 'content': 'private pending'}], 'raw_messages', {})
    other_config = SimpleNamespace(**{
        **asdict(provider._config), 'memory_scope': 'identity', 'user_id': 'bob', 'agent_id': 'planner',
    })
    other = EvidenceArchive(other_config, tmp_path)
    assert first.outbox.status()['pending'] == 1
    assert other.outbox.status()['pending'] == 0


@respx.mock
def test_checkpoint_returns_exact_snapshot_reference_only_after_ack(make_provider):
    provider = make_provider()
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    reference = provider.on_pre_compress([{'role': 'user', 'content': 'checkpoint'}], require_checkpoint=True)
    digest = route.calls[-1].request.url.path.rsplit('/', 1)[-1]
    assert digest in reference
    assert 'host_normalized' in reference
    assert 'robotnotes_evidence' in reference


@respx.mock
@pytest.mark.parametrize('context', ['primary', 'cron', 'flush', 'subagent'])
def test_explicit_evidence_inspection_is_read_only_without_capture(make_provider, context):
    provider = make_provider(enabled=False, context=context)
    payload = json.dumps({'session_id': 'session', 'kind': 'turn', 'capture': 'raw_messages',
                          'messages': [{'role': 'tool', 'content': 'full evidence'}]})
    digest = hashlib.sha256(payload.encode()).hexdigest()
    route = respx.get(f'{BASE}/evidence/{digest}').mock(return_value=httpx.Response(200, json={
        'id': digest, 'payload': payload, 'lineage': {'parent_session_id': 'parent'},
        'created_at': '2026-10-11T00:00:00.000Z', 'expires_at': '2026-10-18T00:00:00.000Z',
    }))
    result = json.loads(provider.handle_tool_call('robotnotes_evidence', {'id': digest}))
    assert result['capture'] == 'raw_messages'
    assert result['snapshot']['messages'] == [{'role': 'tool', 'content': 'full evidence'}]
    assert result['lineage'] == {'parent_session_id': 'parent'}
    assert route.call_count == 1
    assert provider._evidence_outbox is None


@respx.mock
def test_evidence_inspection_rejects_a_payload_that_does_not_match_digest(make_provider):
    provider = make_provider(enabled=False)
    digest = 'a' * 64
    respx.get(f'{BASE}/evidence/{digest}').mock(return_value=httpx.Response(200, json={
        'id': digest, 'payload': '{}', 'lineage': {}, 'created_at': '2026-10-11', 'expires_at': '2026-10-18',
    }))
    result = json.loads(provider.handle_tool_call('robotnotes_evidence', {'id': digest}))
    assert result['code'] == 'invalid_evidence'


def test_evidence_inspection_rejects_non_digest_identifiers(make_provider):
    provider = make_provider(enabled=False)
    result = json.loads(provider.handle_tool_call('robotnotes_evidence', {'id': '../notes'}))
    assert result['code'] == 'invalid_evidence_id'


def test_capture_errors_log_safe_categories_without_exception_payload(make_provider, monkeypatch, caplog):
    provider = make_provider()

    def reject(*args, **kwargs):
        raise ValueError('private raw conversation content')

    monkeypatch.setattr(provider._evidence_archive, 'enqueue', reject)
    provider.sync_turn('hi', 'hello')
    assert 'private raw conversation content' not in caplog.text
    assert 'unsupported_json' in caplog.text


def test_background_flush_errors_log_safe_categories_without_exception_payload(make_provider, monkeypatch, caplog):
    provider = make_provider()

    def reject():
        raise RuntimeError('private response body')

    monkeypatch.setattr(provider._evidence_archive, 'flush', reject)
    provider._evidence_archive.flush_best_effort()
    assert 'private response body' not in caplog.text


@respx.mock
def test_disabled_native_tools_keep_checkpoint_reference_without_native_inspection(make_provider):
    provider = make_provider(native_tools=False)
    route = respx.put(url__regex=BASE + '/evidence/.*').mock(side_effect=ack)
    reference = provider.on_pre_compress([], require_checkpoint=True)
    digest = route.calls[-1].request.url.path.rsplit('/', 1)[-1]
    assert digest in reference
    assert 'robotnotes_evidence' not in reference
    assert provider.get_tool_schemas() == []
    result = json.loads(provider.handle_tool_call('robotnotes_evidence', {'id': digest}))
    assert result['code'] == 'tools_disabled'


@respx.mock
def test_expired_or_purged_evidence_returns_honest_read_error(make_provider):
    provider = make_provider(enabled=False)
    digest = 'a' * 64
    respx.get(f'{BASE}/evidence/{digest}').mock(return_value=httpx.Response(404, json={'error': 'not_found'}))
    result = json.loads(provider.handle_tool_call('robotnotes_evidence', {'id': digest}))
    assert result['code'] == 'not_found'
