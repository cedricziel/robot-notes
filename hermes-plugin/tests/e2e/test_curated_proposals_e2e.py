import json
import os
from uuid import uuid4

import httpx
import pytest

from robot_notes import RobotNotesProvider
from robot_notes.client import ClientError, RobotNotesClient
from robot_notes.config import RobotNotesConfig
from robot_notes.curated_writes import deliver_write, prepare_write

pytestmark = pytest.mark.e2e


@pytest.fixture
def curated_server(tmp_path, monkeypatch, e2e_base_url, e2e_api_key):
    admin = httpx.Client(base_url=e2e_base_url, headers={
        'Authorization': f'Bearer {e2e_api_key}', 'X-Actor': 'human-fixture', 'X-Vault-Id': 'default'})
    scope = 'curated-e2e/' + uuid4().hex
    probe = admin.get('/notes/permissions', params={'path': scope, 'title': 'Draft'})
    if probe.status_code in (404, 405):
        admin.close()
        if os.environ.get('ROBOT_NOTES_REQUIRE_CURATED_E2E') == '1':
            pytest.fail('Required curated server handlers are unavailable')
        pytest.skip('Server predates curated proposal handlers')
    probe.raise_for_status()
    monkeypatch.setenv('ROBOT_NOTES_API_KEY', e2e_api_key)
    RobotNotesConfig.create(base_url=e2e_base_url).save(str(tmp_path))
    provider = RobotNotesProvider()
    provider.initialize('curated-test-session', hermes_home=str(tmp_path))
    client = RobotNotesClient(base_url=e2e_base_url, api_key=e2e_api_key, actor='agent-fixture')

    def set_policy(path, curated=True):
        target = {'kind': 'folder', 'path': path}
        current = admin.get('/knowledge/policies', params=target)
        current.raise_for_status()
        changed = admin.put('/knowledge/policies', headers={'If-Match': str(current.json()['policy_revision'])},
                            json={'target': target, 'policy': {'curated': curated, 'approval': 'evidence_no_conflict'}})
        changed.raise_for_status()

    def decide(result, decision, comment=None):
        detail = client.get_note_proposal(result['note_id'], result['proposal_id'])
        payload = {'decision': decision, 'record_revision': detail['record_revision']}
        if comment:
            payload['comment'] = comment
        response = admin.post(f"/notes/{result['note_id']}/proposals/{result['proposal_id']}/decisions", json=payload)
        response.raise_for_status()
        return response.json()

    set_policy(scope)
    try:
        yield provider, client, admin, scope, set_policy, decide
    finally:
        provider.shutdown()
        client.close()
        admin.close()


def tool(provider, name, args):
    result = json.loads(provider.handle_tool_call(name, args))
    assert 'code' not in result, result
    return result


def create_accepted(curated_server, content='old claim'):
    provider, client, admin, scope, set_policy, decide = curated_server
    draft = tool(provider, 'robotnotes_remember', {'title': 'Note ' + uuid4().hex, 'path': scope, 'content': content})
    assert draft['accepted'] is False
    accepted = decide(draft, 'approve')
    assert accepted['accepted'] is True
    return draft, client.get_note(draft['note_id'])


def test_native_draft_stays_outside_recall_and_has_no_accepted_placeholder(curated_server):
    provider, client, admin, scope, set_policy, decide = curated_server
    keyword = 'pendingonly' + uuid4().hex
    draft = tool(provider, 'robotnotes_remember', {'title': 'Draft', 'path': scope, 'content': keyword})
    assert draft['accepted'] is False
    assert admin.get('/notes/' + draft['note_id']).status_code == 404
    assert keyword not in provider.prefetch(keyword)
    detail = tool(provider, 'robotnotes_proposal', {'note_id': draft['note_id'], 'proposal_id': draft['proposal_id']})
    assert detail['draft']['content'] == keyword
    assert detail['author_agent_origin'] is True
    assert detail['author_kind'] == 'operator'
    assert keyword not in provider.prefetch(keyword)


def test_pending_native_append_and_forget_leave_accepted_note_active(curated_server):
    provider, client, admin, scope, set_policy, decide = curated_server
    original, note = create_accepted(curated_server)
    appended = tool(provider, 'robotnotes_append', {'id': note['id'], 'content': 'new claim'})
    assert appended['accepted'] is False
    assert client.get_note(note['id'])['content'] == 'old claim'
    deleted = tool(provider, 'robotnotes_forget', {'id': note['id']})
    assert deleted['accepted'] is False
    detail = client.get_note_proposal(note['id'], deleted['proposal_id'])
    assert detail['operations'] == [{'type': 'delete_note'}]
    assert client.get_note(note['id'])['content'] == 'old claim'


def test_terminal_and_request_change_inspection_match_real_server_states(curated_server):
    provider, client, admin, scope, set_policy, decide = curated_server
    original, note = create_accepted(curated_server)
    pending = tool(provider, 'robotnotes_append', {'id': note['id'], 'content': 'citation needed'})
    changed = decide(pending, 'request_changes', 'Please cite a source')
    assert changed['accepted'] is False
    detail = tool(provider, 'robotnotes_proposal', {'note_id': note['id'], 'proposal_id': pending['proposal_id']})
    assert detail['state'] == 'changes_requested'
    assert any(comment['body'] == 'Please cite a source' for comment in detail['comments'])
    denied = decide(pending, 'deny')
    assert denied['accepted'] is False
    assert denied['state'] == 'denied'
    assert not any(row['proposal_id'] in {original['proposal_id'], pending['proposal_id']}
                   for row in client.list_note_proposals(note_id=note['id'])['items'])
    audit = client.list_note_proposals(note_id=note['id'], include_terminal=True)['items']
    assert {row['state'] for row in audit} == {'accepted', 'denied'}
    global_audit = tool(provider, 'robotnotes_proposals', {'include_terminal': True})['items']
    assert {original['proposal_id'], pending['proposal_id']} <= {row['proposal_id'] for row in global_audit}


def test_sdk_origin_cannot_direct_edit_or_review_curated_note_with_operator_key(curated_server):
    provider, client, admin, scope, set_policy, decide = curated_server
    original, note = create_accepted(curated_server)
    with pytest.raises(ClientError) as error:
        client.update_note(note['id'], version=note['version'], content='bypass')
    assert error.value.status == 403
    assert client.get_note(note['id'])['content'] == 'old claim'
    pending = tool(provider, 'robotnotes_append', {'id': note['id'], 'content': 'pending'})
    detail = client.get_note_proposal(note['id'], pending['proposal_id'])
    forbidden = client._http.post(f"/notes/{note['id']}/proposals/{pending['proposal_id']}/decisions",
                                 json={'decision': 'approve', 'record_revision': detail['record_revision']})
    assert forbidden.status_code == 403


def test_runtime_origin_closes_designation_race_after_last_permission_check(curated_server, monkeypatch):
    provider, client, admin, scope, set_policy, decide = curated_server
    ordinary = scope + '-ordinary'
    set_policy(ordinary, curated=False)
    created = client.create_note(title='Race', path=ordinary, content='original')
    current = client.get_note(created['id'])
    prepared = prepare_write(client, current=current, title=current['title'], path=ordinary, desired='must not write', refs=[])
    assert prepared['route'] == 'accepted'
    update = client.update_note

    def change_policy_then_update(*args, **kwargs):
        set_policy(ordinary)
        return update(*args, **kwargs)

    monkeypatch.setattr(client, 'update_note', change_policy_then_update)
    with pytest.raises(ClientError) as error:
        deliver_write(client, prepared)
    assert error.value.status == 403
    assert client.get_note(created['id'])['content'] == 'original'


def test_prepared_correction_replays_same_proposal_and_retains_lineage(curated_server):
    provider, client, admin, scope, set_policy, decide = curated_server
    original, note = create_accepted(curated_server, content='old entry\nsecond line')
    prepared = prepare_write(client, current=note, title=note['title'], path=note['path'], desired='new entry\nsecond line',
                             refs=[{'kind': 'conversation', 'session_id': 'raw-host-session', 'tool_call_id': 'raw-call'}])
    first = deliver_write(client, prepared)
    again = deliver_write(client, prepared)
    assert first['proposal_id'] == again['proposal_id']
    assert first['accepted'] is False
    bundle = client.get_note_blocks(note['id'])
    assert bundle['content'] == 'old entry\nsecond line'
    assert 'provenance' in bundle
    detail = client.get_note_proposal(note['id'], first['proposal_id'])
    assert detail['operations'][0]['supersedes'][0]['kind'] == 'block_revision'
    assert detail['evidence_refs'] == [{'kind': 'conversation', 'session_id': 'raw-host-session', 'tool_call_id': 'raw-call'}]
