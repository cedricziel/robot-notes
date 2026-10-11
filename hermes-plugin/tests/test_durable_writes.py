import json

import httpx
import respx

from robot_notes import RobotNotesProvider

BASE = 'https://notes.example.com'


def make_provider(tmp_path, monkeypatch):
    monkeypatch.setenv('ROBOT_NOTES_API_KEY', 'test-key')
    (tmp_path / 'robot_notes.json').write_text(json.dumps({'base_url': BASE, 'durable_writes': True}))
    provider = RobotNotesProvider()
    provider.initialize('session', hermes_home=str(tmp_path), agent_context='primary')
    return provider


@respx.mock
def test_failed_mirror_survives_restart_then_delivers(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    failed = respx.get(f'{BASE}/notes').mock(return_value=httpx.Response(503))
    provider.on_memory_write('add', 'memory', 'Durable fact')
    provider.flush_memory_writes()
    assert provider.memory_health()['retry_queue']['pending'] == 1
    provider.shutdown()
    failed.mock(return_value=httpx.Response(200, json={'items': [], 'next_cursor': None}))
    created = respx.post(f'{BASE}/notes').mock(return_value=httpx.Response(201, json={'id': 'n1'}))
    resumed = make_provider(tmp_path, monkeypatch)
    resumed.flush_memory_writes()
    assert resumed.memory_health()['retry_queue']['pending'] == 0
    assert json.loads(created.calls.last.request.content)['content'] == 'Durable fact'
    resumed.shutdown()


@respx.mock
def test_changed_destination_does_not_replay_old_pending_write(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    respx.get(f'{BASE}/notes').mock(return_value=httpx.Response(503))
    provider.on_memory_write('add', 'memory', 'Private fact')
    provider.flush_memory_writes()
    provider.shutdown()
    (tmp_path / 'robot_notes.json').write_text(json.dumps({'base_url': BASE, 'durable_writes': True, 'vault_id': 'other'}))
    resumed = RobotNotesProvider()
    resumed.initialize('other', hermes_home=str(tmp_path), agent_context='primary')
    resumed.flush_memory_writes()
    assert resumed.memory_health()['retry_queue']['pending'] == 0
    resumed.shutdown()


@respx.mock
def test_subagent_never_replays_primary_queue(tmp_path, monkeypatch):
    provider = make_provider(tmp_path, monkeypatch)
    route = respx.get(f'{BASE}/notes').mock(return_value=httpx.Response(503))
    provider.on_memory_write('add', 'memory', 'Fact')
    provider.flush_memory_writes()
    provider.shutdown()
    calls = route.call_count
    child = RobotNotesProvider()
    child.initialize('child', hermes_home=str(tmp_path), agent_context='subagent')
    child.on_turn_start(1, 'retry')
    assert route.call_count == calls
    assert child.memory_health()['retry_queue'] == 'disabled'
    child.shutdown()


def _note_server_with_lost_update_ack(state):
    respx.get(f'{BASE}/notes').mock(side_effect=lambda request: httpx.Response(
        200, json={'items': [{'id': 'n1', 'title': 'Memory', 'version': state['version']}], 'next_cursor': None}
    ))
    respx.get(f'{BASE}/notes/n1').mock(side_effect=lambda request: httpx.Response(
        200, json={'id': 'n1', 'title': 'Memory', 'path': 'Hermes', 'version': state['version'], 'content': state['content']}
    ))

    def update(request):
        state['content'] = json.loads(request.content)['content']
        state['version'] += 1
        raise httpx.ReadError('acknowledgement lost after the server committed')

    return respx.put(f'{BASE}/notes/n1').mock(side_effect=update)


def _enqueue_before_flush(provider, monkeypatch, action, content, metadata=None):
    provider.flush_memory_writes()
    with monkeypatch.context() as paused:
        paused.setattr(provider, '_start_delivery', lambda: None)
        provider.on_memory_write(action, 'memory', content, metadata)


@respx.mock
def test_lost_remove_ack_does_not_reapply_selector_after_restart(tmp_path, monkeypatch):
    state = {'content': 'x\nx other', 'version': 1}
    updates = _note_server_with_lost_update_ack(state)
    provider = make_provider(tmp_path, monkeypatch)
    _enqueue_before_flush(provider, monkeypatch, 'remove', '', {'old_text': 'x'})
    provider.flush_memory_writes()
    assert state['content'] == 'x other'
    assert provider.memory_health()['retry_queue']['pending'] == 1
    provider.shutdown()

    resumed = make_provider(tmp_path, monkeypatch)
    resumed.flush_memory_writes()

    assert state['content'] == 'x other'
    assert updates.call_count == 1
    assert resumed.memory_health()['retry_queue']['pending'] == 0
    resumed.shutdown()


@respx.mock
def test_lost_multiline_add_ack_does_not_duplicate_block_after_restart(tmp_path, monkeypatch):
    state = {'content': 'head', 'version': 1}
    updates = _note_server_with_lost_update_ack(state)
    provider = make_provider(tmp_path, monkeypatch)
    _enqueue_before_flush(provider, monkeypatch, 'add', 'first\nsecond')
    provider.flush_memory_writes()
    assert state['content'] == 'head\nfirst\nsecond'
    provider.shutdown()

    resumed = make_provider(tmp_path, monkeypatch)
    resumed.flush_memory_writes()

    assert state['content'] == 'head\nfirst\nsecond'
    assert updates.call_count == 1
    assert resumed.memory_health()['retry_queue']['pending'] == 0
    resumed.shutdown()


@respx.mock
def test_ambiguous_write_followed_by_concurrent_edit_blocks_without_reapplying(tmp_path, monkeypatch):
    state = {'content': 'x\nx other', 'version': 1}
    updates = _note_server_with_lost_update_ack(state)
    provider = make_provider(tmp_path, monkeypatch)
    _enqueue_before_flush(provider, monkeypatch, 'remove', '', {'old_text': 'x'})
    provider.flush_memory_writes()
    provider.shutdown()
    state.update(content='x other\nremote addition', version=3)

    resumed = make_provider(tmp_path, monkeypatch)
    resumed.flush_memory_writes()

    assert state['content'] == 'x other\nremote addition'
    assert updates.call_count == 1
    assert resumed.memory_health()['retry_queue']['pending'] == 1
    assert resumed.memory_health()['retry_queue']['blocked'] is True
    resumed.shutdown()
