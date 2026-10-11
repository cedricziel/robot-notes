import httpx
import pytest
import respx
from robot_notes import RobotNotesProvider
from robot_notes.client import RobotNotesClient
from robot_notes.config import RobotNotesConfig


def test_recall_configuration_roundtrips(tmp_path):
    configured = RobotNotesConfig.create(
        recall_path="projects/launch", recall_max_bytes=1400, recall_expand_chars=1000
    )
    configured.save(str(tmp_path))
    restored = RobotNotesConfig.load(str(tmp_path))
    assert restored.recall_path == "projects/launch"
    assert restored.recall_max_bytes == 1400
    assert restored.recall_expand_chars == 1000


@pytest.mark.parametrize(
    "options",
    [
        {"recall_path": "../other"},
        {"recall_path": "/root"},
        {"recall_path": "a//b"},
        {"recall_max_bytes": True},
        {"recall_max_bytes": -1},
        {"recall_max_bytes": 65537},
        {"recall_expand_chars": 1},
        {"recall_expand_chars": -1},
    ],
)
def test_invalid_recall_settings_are_rejected(options):
    with pytest.raises(ValueError):
        RobotNotesConfig.create(**options)


@respx.mock
def test_evidence_fetch_uses_recall_timeout():
    route = respx.get("https://notes.example.com/notes/1").respond(
        200, json={"id": "1", "title": "Evidence", "content": "match", "path": ""}
    )
    client = RobotNotesClient(
        base_url="https://notes.example.com",
        api_key="test",
        actor="test",
        recall_timeout=0.25,
    )
    try:
        client.get_note("1", recall=True)
        assert route.calls.last.request.extensions["timeout"]["read"] == 0.25
    finally:
        client.close()


@respx.mock
def test_failed_expansion_returns_no_partial_evidence(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "test")
    config = RobotNotesConfig.create(
        base_url="https://notes.example.com",
        recall_max_bytes=1000,
        recall_expand_chars=200,
    )
    config.save(str(tmp_path))
    respx.get("https://notes.example.com/search").respond(
        200, json={"items": [{"id": "1", "title": "Evidence", "snippet": "match"}]}
    )
    respx.get("https://notes.example.com/notes/1").mock(
        side_effect=httpx.ReadTimeout("slow")
    )
    provider = RobotNotesProvider()
    try:
        provider.initialize("test", hermes_home=str(tmp_path))
        assert provider.prefetch("match") == ""
    finally:
        provider.shutdown()


@pytest.fixture
def bounded_provider(tmp_path, monkeypatch):
    monkeypatch.setenv('ROBOT_NOTES_API_KEY', 'test')
    configured = RobotNotesConfig.create(base_url='https://notes.example.com',
                                         recall_max_bytes=1000, recall_expand_chars=100)
    configured.save(str(tmp_path))
    provider = RobotNotesProvider()
    provider.initialize('session', hermes_home=str(tmp_path))
    yield provider
    provider.shutdown()


@respx.mock
def test_successful_bounded_expansion_finishes_recall_health(bounded_provider):
    respx.get('https://notes.example.com/search').respond(200, json={'items': [
        {'id': '1', 'title': 'Evidence', 'snippet': 'match', 'path': ''},
    ]})
    respx.get('https://notes.example.com/notes/1').respond(200, json={
        'id': '1', 'title': 'Evidence', 'content': 'match expanded', 'path': '', 'updated_at': 'current',
    })
    assert 'match expanded' in bounded_provider.prefetch('match')
    assert bounded_provider.memory_health()['recall'] == {'state': 'matched'}


@respx.mock
def test_budget_omitting_all_results_finishes_recall_health_as_empty(bounded_provider):
    bounded_provider._config = RobotNotesConfig.create(base_url='https://notes.example.com', recall_max_bytes=10)
    respx.get('https://notes.example.com/search').respond(200, json={'items': [
        {'id': '1', 'title': 'Evidence', 'snippet': 'match', 'path': ''},
    ]})
    assert bounded_provider.prefetch('match') == ''
    assert bounded_provider.memory_health()['recall'] == {'state': 'empty'}


@respx.mock
@pytest.mark.parametrize('invalid', [
    None, [], {'id': '1', 'title': None, 'content': 'match', 'path': ''},
    {'id': '1', 'title': 'Evidence', 'content': {}, 'path': ''},
    {'id': '1', 'title': 'Evidence', 'content': 'match', 'path': []},
    {'id': 'wrong', 'title': 'Evidence', 'content': 'match', 'path': ''},
    {'id': '1', 'title': 'Evidence', 'content': 'match', 'path': '', 'updated_at': None},
])
def test_malformed_expansion_rejects_the_entire_context_and_finishes_health(bounded_provider, invalid):
    respx.get('https://notes.example.com/search').respond(200, json={'items': [
        {'id': 'good', 'title': 'Good evidence', 'snippet': 'match', 'path': ''},
        {'id': '1', 'title': 'Bad evidence', 'snippet': 'match', 'path': ''},
    ]})
    respx.get('https://notes.example.com/notes/good').respond(200, json={
        'id': 'good', 'title': 'Good evidence', 'content': 'match expanded', 'path': '', 'updated_at': 'current',
    })
    respx.get('https://notes.example.com/notes/1').respond(200, json=invalid)
    assert bounded_provider.prefetch('match') == ''
    assert bounded_provider.memory_health()['recall'] == {'state': 'failed', 'reason': 'other'}
