import httpx
import pytest
import respx

from robot_notes.client import ClientError, ErrorKind, RobotNotesClient


class FakeClock:
    def __init__(self, now: float = 0.0):
        self._now = now

    def __call__(self) -> float:
        return self._now

    def advance(self, seconds: float) -> None:
        self._now += seconds


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
def test_search_forwards_path_when_given(client):
    route = respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": []})
    )

    client.search("budget", path="Hermes", limit=5)

    sent = route.calls.last.request
    assert sent.url.params["path"] == "Hermes"
    assert sent.url.params["limit"] == "5"


@respx.mock
def test_search_omits_path_param_when_not_given(client):
    route = respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(200, json={"items": []})
    )

    client.search("budget")

    assert "path" not in route.calls.last.request.url.params


@respx.mock
def test_list_notes_returns_items_and_next_cursor(client):
    respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "01ABC", "title": "Budget"}], "next_cursor": "01DEF"}
        )
    )

    result = client.list_notes()

    assert result["items"][0]["id"] == "01ABC"
    assert result["next_cursor"] == "01DEF"


@respx.mock
def test_list_notes_forwards_path_and_after(client):
    route = respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(200, json={"items": [], "next_cursor": None})
    )

    client.list_notes(path="Hermes", after="01CURSOR", limit=10)

    sent = route.calls.last.request
    assert sent.url.params["path"] == "Hermes"
    assert sent.url.params["after"] == "01CURSOR"
    assert sent.url.params["limit"] == "10"


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
def test_find_note_by_title_uses_title_filter_when_supported(client):
    route = respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(
            200, json={"items": [{"id": "01ABC", "title": "Session X", "version": 2}], "next_cursor": None}
        )
    )

    result = client.find_note_by_title("Session X", path="conversations/agent")

    assert result["id"] == "01ABC"
    assert route.call_count == 1
    sent = route.calls.last.request
    assert sent.url.params["title"] == "Session X"
    assert sent.url.params["path"] == "conversations/agent"


@respx.mock
def test_find_note_by_title_filter_miss_does_not_fall_back_to_scan(client):
    route = respx.get("https://notes.example.com/notes").mock(
        return_value=httpx.Response(200, json={"items": [], "next_cursor": None})
    )

    result = client.find_note_by_title("Missing", path="conversations/agent")

    assert result is None


@respx.mock
def test_create_note_path_conflict_raises_path_conflict_not_version_conflict(client):
    """A 409 from `POST /notes` is a title/path collision, per API.md — it must
    not be lumped in with the version-race 409 from `PUT /notes/{id}`."""
    respx.post("https://notes.example.com/notes").mock(
        return_value=httpx.Response(409, json={"error": "path_conflict"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.create_note(title="Inbox", content="hello", path="Hermes")

    exc = exc_info.value
    assert exc.path_conflict is True
    assert exc.version_conflict is False
    assert exc.kind is ErrorKind.PATH_CONFLICT
    assert exc.code == "path_conflict"


@respx.mock
def test_update_note_path_conflict_raises_path_conflict(client):
    """`PUT /notes/{id}` also returns 409 `path_conflict` (a rename/move that
    collides with another note) alongside its 409 `version_conflict`."""
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(409, json={"error": "path_conflict"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.update_note("01XYZ", version=1, content="x")

    assert exc_info.value.kind is ErrorKind.PATH_CONFLICT


@respx.mock
def test_update_note_locked_raises_locked_with_holder(client):
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(
            423,
            json={"error": "locked", "lock": {"holder": "alice", "expires_at": "2026-04-25T10:15:23Z"}},
        )
    )

    with pytest.raises(ClientError) as exc_info:
        client.update_note("01XYZ", version=1, content="x")

    exc = exc_info.value
    assert exc.locked is True
    assert exc.kind is ErrorKind.LOCKED
    assert exc.lock_holder == "alice"
    assert exc.details["lock"]["expires_at"] == "2026-04-25T10:15:23Z"


@respx.mock
def test_401_raises_auth(client):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(401, json={"error": "unauthorized"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.search("budget")

    exc = exc_info.value
    assert exc.auth_error is True
    assert exc.kind is ErrorKind.AUTH
    assert exc.code == "unauthorized"


@respx.mock
def test_403_raises_auth(client):
    respx.get("https://notes.example.com/search").mock(
        return_value=httpx.Response(403, json={"error": "insufficient_scope"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.search("budget")

    exc = exc_info.value
    assert exc.auth_error is True
    assert exc.code == "insufficient_scope"


@respx.mock
def test_error_body_flat_shape_is_parsed_into_code_and_details(client):
    """The notes routes actually in production use the flat
    ``{"error": "version_conflict", "current": {...}}`` shape, not the nested
    envelope API.md documents — the client must handle both."""
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(
            409,
            json={
                "error": "version_conflict",
                "current": {"id": "01XYZ", "version": 7, "content": "server copy"},
            },
        )
    )

    with pytest.raises(ClientError) as exc_info:
        client.update_note("01XYZ", version=1, content="x")

    exc = exc_info.value
    assert exc.code == "version_conflict"
    assert exc.current_version == 7
    assert exc.current_content == "server copy"


@respx.mock
def test_error_body_nested_envelope_shape_is_parsed_into_code_and_details(client):
    """The nested envelope documented in API.md
    (``{"error": {"code", "message", "details"}}``) must also be understood."""
    respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(
            409,
            json={
                "error": {
                    "code": "version_conflict",
                    "message": "Note version has advanced; reload before saving.",
                    "details": {"current_version": 9},
                }
            },
        )
    )

    with pytest.raises(ClientError) as exc_info:
        client.update_note("01XYZ", version=1, content="x")

    exc = exc_info.value
    assert exc.code == "version_conflict"
    assert exc.server_message == "Note version has advanced; reload before saving."
    assert exc.current_version == 9


@respx.mock
def test_write_note_with_retry_uses_current_version_from_error_body_without_a_get(client):
    """When the 409 body already carries the current version, retry from it
    directly instead of spending an extra GET round trip."""
    get_route = respx.get("https://notes.example.com/notes/01XYZ")
    put_route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        side_effect=[
            httpx.Response(
                409,
                json={"error": "version_conflict", "current": {"id": "01XYZ", "version": 7}},
            ),
            httpx.Response(200, json={"id": "01XYZ", "version": 8}),
        ]
    )

    result = client.write_note_with_retry("01XYZ", version=3, content="new content")

    assert not get_route.called
    assert put_route.call_count == 2
    assert put_route.calls[1].request.headers["if-match"] == "7"
    assert result["version"] == 8


@respx.mock
def test_write_note_with_retry_does_not_retry_path_conflict(client):
    """A path conflict is a different problem than a version race — retrying
    at a fresher version can never fix it, so it must surface immediately."""
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(409, json={"error": "path_conflict"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.write_note_with_retry("01XYZ", version=1, content="x")

    assert exc_info.value.path_conflict is True
    assert route.call_count == 1


@respx.mock
def test_find_note_by_title_falls_back_to_scan_on_http_400(client):
    route = respx.get("https://notes.example.com/notes").mock(
        side_effect=[
            httpx.Response(400, json={"error": {"code": "validation_failed"}}),
            httpx.Response(
                200, json={"items": [{"id": "01ABC", "title": "Session X", "version": 1}], "next_cursor": None}
            ),
        ]
    )

    result = client.find_note_by_title("Session X", path="conversations/agent")

    assert result["id"] == "01ABC"
    assert route.call_count == 2
    first_request, second_request = route.calls[0].request, route.calls[1].request
    assert first_request.url.params["title"] == "Session X"
    assert "title" not in second_request.url.params
    assert second_request.url.params["sort"] == "updated_desc"


@respx.mock
def test_find_note_by_title_scan_finds_note_on_third_page(client):
    respx.get("https://notes.example.com/notes").mock(
        side_effect=[
            httpx.Response(400, json={}),
            httpx.Response(200, json={"items": [{"id": "1", "title": "Other"}], "next_cursor": "c1"}),
            httpx.Response(200, json={"items": [{"id": "2", "title": "Other2"}], "next_cursor": "c2"}),
            httpx.Response(
                200, json={"items": [{"id": "3", "title": "Target", "version": 5}], "next_cursor": None}
            ),
        ]
    )

    result = client.find_note_by_title("Target", path="conversations/agent")

    assert result == {"id": "3", "title": "Target", "version": 5}


@respx.mock
def test_find_note_by_title_scan_returns_none_after_exhausting_pages(client):
    respx.get("https://notes.example.com/notes").mock(
        side_effect=[
            httpx.Response(400, json={}),
            httpx.Response(200, json={"items": [{"id": "1", "title": "Other"}], "next_cursor": "c1"}),
            httpx.Response(200, json={"items": [{"id": "2", "title": "Other2"}], "next_cursor": None}),
        ]
    )

    result = client.find_note_by_title("Missing", path="conversations/agent")

    assert result is None


@respx.mock
def test_find_note_by_title_scan_stops_after_one_page_when_found(client):
    route = respx.get("https://notes.example.com/notes").mock(
        side_effect=[
            httpx.Response(400, json={}),
            httpx.Response(
                200, json={"items": [{"id": "01ABC", "title": "Session X", "version": 1}], "next_cursor": "c1"}
            ),
        ]
    )

    result = client.find_note_by_title("Session X", path="conversations/agent")

    assert result["id"] == "01ABC"
    # 1 request for the unsupported title filter + exactly 1 scan page, even
    # though the first scan page's next_cursor implies more pages exist.
    assert route.call_count == 2


@respx.mock
def test_find_note_by_title_propagates_non_400_errors_from_filter_attempt(client):
    respx.get("https://notes.example.com/notes").mock(return_value=httpx.Response(500))

    with pytest.raises(ClientError):
        client.find_note_by_title("Session X", path="conversations/agent")


@respx.mock
def test_write_note_with_retry_does_not_retry_locked(client):
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(423, json={"error": "locked", "lock": {"holder": "alice"}})
    )

    with pytest.raises(ClientError) as exc_info:
        client.write_note_with_retry("01XYZ", version=1, content="x")

    assert exc_info.value.locked is True
    assert route.call_count == 1


@respx.mock
def test_append_note_with_retry_does_not_retry_path_conflict(client):
    respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 1, "content": "x"})
    )
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(409, json={"error": "path_conflict"})
    )

    with pytest.raises(ClientError) as exc_info:
        client.append_note_with_retry("01XYZ", build_content=lambda current: current + "\nmore")

    assert exc_info.value.path_conflict is True
    assert route.call_count == 1


@respx.mock
def test_append_note_with_retry_does_not_retry_locked(client):
    respx.get("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "version": 1, "content": "x"})
    )
    route = respx.put("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(423, json={"error": "locked", "lock": {"holder": "bob"}})
    )

    with pytest.raises(ClientError) as exc_info:
        client.append_note_with_retry("01XYZ", build_content=lambda current: current + "\nmore")

    assert exc_info.value.locked is True
    assert route.call_count == 1


@respx.mock
def test_delete_note(client):
    route = respx.delete("https://notes.example.com/notes/01XYZ").mock(
        return_value=httpx.Response(200, json={"id": "01XYZ", "deleted": True})
    )

    result = client.delete_note("01XYZ")

    assert route.called
    assert result["deleted"] is True


# -- Circuit breaker --------------------------------------------------------


@respx.mock
def test_search_passes_recall_timeout_not_the_client_default():
    client = RobotNotesClient(
        base_url="https://notes.example.com",
        api_key="secret-key",
        actor="hermes-bot",
        recall_timeout=3.0,
        write_timeout=10.0,
    )
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(200, json={"items": []}))

    client.search("budget")

    sent_timeout = respx.calls.last.request.extensions["timeout"]
    assert sent_timeout["connect"] == pytest.approx(3.0)


@respx.mock
def test_five_consecutive_network_errors_open_the_breaker():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("boom"))

    for _ in range(5):
        with pytest.raises(ClientError):
            client.search("budget")

    with pytest.raises(ClientError) as exc_info:
        client.search("budget")

    assert exc_info.value.kind is ErrorKind.CIRCUIT_OPEN
    assert exc_info.value.circuit_open is True


@respx.mock
def test_five_consecutive_5xx_responses_open_the_breaker():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(503))

    for _ in range(5):
        with pytest.raises(ClientError):
            client.search("budget")

    with pytest.raises(ClientError) as exc_info:
        client.search("budget")

    assert exc_info.value.kind is ErrorKind.CIRCUIT_OPEN


@respx.mock
def test_open_breaker_short_circuits_without_making_a_request():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    route = respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("boom"))

    for _ in range(5):
        with pytest.raises(ClientError):
            client.search("budget")
    assert route.call_count == 5

    with pytest.raises(ClientError):
        client.search("budget")

    # the 6th call never reached the transport
    assert route.call_count == 5


@respx.mock
def test_404_and_409_do_not_count_toward_the_breaker():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    respx.get("https://notes.example.com/notes/missing").mock(return_value=httpx.Response(404))
    respx.put("https://notes.example.com/notes/01XYZ").mock(return_value=httpx.Response(409))

    for _ in range(10):
        with pytest.raises(ClientError):
            client.get_note("missing")
        with pytest.raises(ClientError):
            client.update_note("01XYZ", version=1, content="x")

    respx.get("https://notes.example.com/search").mock(return_value=httpx.Response(200, json={"items": []}))
    # breaker never tripped, so a normal call still goes through
    assert client.search("budget") == []


@respx.mock
def test_breaker_closes_again_after_the_cooldown_elapses():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    route = respx.get("https://notes.example.com/search").mock(side_effect=httpx.ConnectError("boom"))

    for _ in range(5):
        with pytest.raises(ClientError):
            client.search("budget")
    with pytest.raises(ClientError) as exc_info:
        client.search("budget")
    assert exc_info.value.kind is ErrorKind.CIRCUIT_OPEN

    clock.advance(60.0)
    route.side_effect = None
    route.return_value = httpx.Response(200, json={"items": []})

    assert client.search("budget") == []


@respx.mock
def test_a_success_after_some_failures_resets_the_breaker():
    clock = FakeClock()
    client = RobotNotesClient(
        base_url="https://notes.example.com", api_key="secret-key", actor="hermes-bot", clock=clock
    )
    respx.get("https://notes.example.com/search").mock(
        side_effect=[
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
            httpx.Response(200, json={"items": []}),
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
            httpx.ConnectError("boom"),
        ]
    )

    for _ in range(4):
        with pytest.raises(ClientError):
            client.search("budget")
    assert client.search("budget") == []  # success resets the consecutive-failure count
    for _ in range(4):
        with pytest.raises(ClientError) as exc_info:
            client.search("budget")
    # still below threshold again (4 failures since the reset), so still a network error
    assert exc_info.value.kind is ErrorKind.NETWORK_ERROR


@respx.mock
def test_delete_note_handles_empty_204_body(client):
    """The real server responds 204 No Content with no body (see
    server/API.md); this must not raise trying to decode JSON from it."""
    respx.delete("https://notes.example.com/notes/01XYZ").mock(return_value=httpx.Response(204))

    result = client.delete_note("01XYZ")

    assert result == {}
