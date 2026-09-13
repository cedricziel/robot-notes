import httpx
import pytest
import respx

from robot_notes.client import ClientError, RobotNotesClient


@pytest.fixture
def client():
    return RobotNotesClient(base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot")


@respx.mock
def test_requests_carry_bearer_and_actor_headers(client):
    route = respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": []})
    )

    client.search("budget")

    assert route.called
    sent = route.calls.last.request
    assert sent.headers["authorization"] == "Bearer secret-key"
    assert sent.headers["x-actor"] == "hermes-bot"


@respx.mock
def test_search_returns_items(client):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "01ABC", "title": "Budget", "path": "", "snippet": "<mark>budget</mark>", "rank": 1.0}]}
        )
    )

    result = client.search("budget")

    sent = respx.calls.last.request
    assert sent.url.params["q"] == "budget"

    assert result[0]["id"] == "01ABC"


@respx.mock
def test_get_note_not_found_raises_client_error(client):
    respx.get("https://notes.example.com/notes/missing").mock(return_value=httpx.Response(404))

    with pytest.raises(ClientError) as exc_info:
        client.get_note("missing")

    assert exc_info.value.not_found is True


@respx.mock
def test_create_note_posts_body_and_returns_record(client):
    route = respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(201, json={"id": "01XYZ", "title": "Inbox", "version": 1})
    )

    result = client.create_note(title="Inbox", content="hello", path="Hermes")

    assert route.called
    assert result["id"] == "01XYZ"


@respx.mock
def test_update_note_sends_if_match_header(client):
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 2})
    )

    client.update_note("01XYZ", version=1, content="new content")

    assert route.calls.last.request.headers["if-match"] == "1"


@respx.mock
def test_append_note_with_retry_retries_on_version_conflict_then_succeeds(client):
    respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 3, "content": "line one"})
    )
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        side_effect=[
            httpx.Response(409, json={"error": "version_conflict", "version": 2}),
            httpx.Response(409, json={"error": "version_conflict", "version": 3}),
            httpx.Response(200, json={"id": "01XYZ", "version": 4}),
        ]
    )

    result = client.append_note_with_retry(
        "01XYZ", build_content=lambda current: current + "\nappended", max_attempts=3
    )

    assert route.call_count == 3
    assert result["version"] == 4


@respx.mock
def test_append_note_with_retry_gives_up_after_max_attempts(client):
    respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 1, "content": ""})
    )
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(409, json={"error": "version_conflict", "version": 99})
    )

    with pytest.raises(ClientError) as exc_info:
        client.append_note_with_retry("01XYZ", build_content=lambda current: "x", max_attempts=3)

    assert exc_info.value.version_conflict is True


@respx.mock
def test_write_note_with_retry_skips_the_initial_read(client):
    get_route = respx.get("https://notes.example.com/notes/01XYZ")
    put_route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 4})
    )

    result = client.write_note_with_retry("01XYZ", version=3, content="new content")

    assert not get_route.called
    assert put_route.called
    assert result["version"] == 4


@respx.mock
def test_write_note_with_retry_rereads_only_the_version_on_conflict(client):
    get_route = respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 5, "content": "irrelevant"})
    )
    put_route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        side_effect=[
            httpx.Response(409, json={"error": "version_conflict", "version": 5}),
            httpx.Response(200, json={"id": "01XYZ", "version": 6}),
        ]
    )

    result = client.write_note_with_retry("01XYZ", version=3, content="new content")

    assert get_route.call_count == 1
    assert put_route.call_count == 2
    assert result["version"] == 6


@respx.mock
def test_write_note_with_retry_gives_up_after_max_attempts(client):
    respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 1})
    )
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(409, json={"error": "version_conflict", "version": 99})
    )

    with pytest.raises(ClientError) as exc_info:
        client.write_note_with_retry("01XYZ", version=1, content="x", max_attempts=3)

    assert exc_info.value.version_conflict is True


@respx.mock
def test_network_failure_raises_client_error_not_a_raw_exception(client):
    respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("boom"))

    with pytest.raises(ClientError) as exc_info:
        client.search("budget")

    assert exc_info.value.network_error is True


@respx.mock
def test_delete_note(client):
    route = respx.delete("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "deleted": True})
    )

    result = client.delete_note("01XYZ")

    assert route.called
    assert result["deleted"] is True
