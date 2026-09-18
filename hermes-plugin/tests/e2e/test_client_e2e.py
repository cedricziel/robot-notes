"""End-to-end coverage of RobotNotesClient against a live robot-notes server.

Everything mocked with respx in ``tests/test_client.py`` is real HTTP here:
the actual 201/404/409 status codes, the actual error envelope shape, and
actual optimistic-concurrency behavior. Selected only with
``python -m pytest -m e2e`` and only runs when ``ROBOT_NOTES_E2E_BASE_URL`` /
``ROBOT_NOTES_E2E_API_KEY`` are set (see conftest.py).
"""

from __future__ import annotations

import uuid

import httpx
import pytest

from robot_notes.client import ClientError, ErrorKind, RobotNotesClient

pytestmark = pytest.mark.e2e


def _uid() -> str:
    return uuid.uuid4().hex[:12]


def test_create_get_update_delete_round_trip(e2e_client: RobotNotesClient):
    title = f"e2e-roundtrip-{_uid()}"
    path = f"e2e-roundtrip-{_uid()}"

    created = e2e_client.create_note(title=title, content="hello from e2e", path=path)
    assert created["title"] == title
    assert created["path"] == path
    assert created["version"] == 1
    assert created["content"] == "hello from e2e"

    fetched = e2e_client.get_note(created["id"])
    assert fetched["content"] == "hello from e2e"
    assert fetched["version"] == 1

    updated = e2e_client.update_note(created["id"], version=fetched["version"], content="updated content")
    assert updated["content"] == "updated content"
    assert updated["version"] == fetched["version"] + 1

    e2e_client.delete_note(created["id"])

    with pytest.raises(ClientError) as exc_info:
        e2e_client.get_note(created["id"])
    assert exc_info.value.not_found is True


def test_list_notes_filters_by_path(e2e_client: RobotNotesClient):
    target_path = f"e2e-list-{_uid()}"
    other_path = f"e2e-list-other-{_uid()}"
    target_title = f"e2e-{_uid()}"

    e2e_client.create_note(title=target_title, content="in the target folder", path=target_path)
    e2e_client.create_note(title=f"e2e-{_uid()}", content="elsewhere", path=other_path)

    result = e2e_client.list_notes(path=target_path)

    titles = [item["title"] for item in result["items"]]
    assert target_title in titles
    assert all(item["path"] == target_path for item in result["items"])


def test_search_finds_created_note(e2e_client: RobotNotesClient):
    path = f"e2e-search-{_uid()}"
    # A single dash-free token: FTS5's default tokenizer splits on
    # punctuation, so a hyphenated needle would fragment into several tokens.
    needle = f"unobtainium{uuid.uuid4().hex}"

    e2e_client.create_note(title=f"e2e-{_uid()}", content=f"the rare word {needle} appears here", path=path)

    items = e2e_client.search(needle)

    assert any(item.get("title", "").startswith("e2e-") for item in items)
    assert items, f"expected at least one search hit for {needle!r}"


def test_create_with_colliding_title_returns_409_path_conflict(
    e2e_client: RobotNotesClient, e2e_base_url, e2e_api_key
):
    """The server does reject the collision with a distinct 409 today — the bug
    (tracked by #238) is only that RobotNotesClient folds that 409 into the same
    ``version_conflict`` bucket as a stale PUT. This asserts the real server
    envelope via a raw request (RobotNotesClient discards the body); see
    test_create_colliding_title_is_distinct_path_conflict below for the desired,
    still-unimplemented client-level distinction."""
    title = f"e2e-collide-{_uid()}"
    path = f"e2e-collide-{_uid()}"

    e2e_client.create_note(title=title, content="first", path=path)

    with pytest.raises(ClientError) as exc_info:
        e2e_client.create_note(title=title, content="second", path=path)
    assert exc_info.value.kind is ErrorKind.VERSION_CONFLICT  # today's (mis)mapping

    response = httpx.post(
        f"{e2e_base_url}/notes",
        headers={"Authorization": f"Bearer {e2e_api_key}", "X-Actor": "hermes-e2e"},
        json={"title": title, "content": "second", "path": path},
    )
    assert response.status_code == 409
    assert response.json() == {"error": "path_conflict"}


@pytest.mark.xfail(
    strict=True,
    reason="RobotNotesClient maps every 409 to ErrorKind.VERSION_CONFLICT, including a "
    "path collision on create; https://github.com/cedricziel/robot-notes/issues/238 "
    "fixes this by surfacing the server's error envelope",
)
def test_create_colliding_title_is_distinct_path_conflict(e2e_client: RobotNotesClient):
    """Desired behaviour once #238 lands: a colliding-title create must raise a
    ClientError distinguishable from a genuine version conflict, e.g. via a
    dedicated ErrorKind.PATH_CONFLICT (mirroring the server's
    ``{"error": "path_conflict"}``), not the same VERSION_CONFLICT a stale PUT
    raises. This flips to an unexpected pass (and thus a hard failure, since it
    is `strict=True`) the day the client learns to tell the two apart."""
    title = f"e2e-collide-{_uid()}"
    path = f"e2e-collide-{_uid()}"

    e2e_client.create_note(title=title, content="first", path=path)

    with pytest.raises(ClientError) as exc_info:
        e2e_client.create_note(title=title, content="second", path=path)

    err = exc_info.value
    assert err.kind is ErrorKind.PATH_CONFLICT
    assert err.path_conflict is True
    assert err.version_conflict is False


def test_stale_version_put_is_rejected_with_current_version(e2e_client: RobotNotesClient, e2e_base_url, e2e_api_key):
    """Exercises the client's own version-conflict mapping (already correct for a
    genuine stale write) *and* the raw server envelope, since
    ``ClientError`` currently discards the response body entirely (also part of
    #238) and so cannot itself assert on ``current`` version details."""
    path = f"e2e-stale-{_uid()}"
    created = e2e_client.create_note(title=f"e2e-{_uid()}", content="v1", path=path)
    note_id = created["id"]
    stale_version = created["version"]

    # Advance the note so `stale_version` (1) is now behind the real version (2).
    e2e_client.update_note(note_id, version=stale_version, content="v2")

    with pytest.raises(ClientError) as exc_info:
        e2e_client.update_note(note_id, version=stale_version, content="v3-should-not-land")
    assert exc_info.value.version_conflict is True

    # Confirm the real server envelope: a raw request (not through
    # RobotNotesClient, which discards the body) so the test still passes
    # before #238 teaches the client to expose these details itself.
    response = httpx.put(
        f"{e2e_base_url}/notes/{note_id}",
        headers={
            "Authorization": f"Bearer {e2e_api_key}",
            "X-Actor": "hermes-e2e",
            "If-Match": str(stale_version),
        },
        json={"content": "v3-should-not-land"},
    )
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "version_conflict"
    assert body["current"]["version"] == 2

    final = e2e_client.get_note(note_id)
    assert final["content"] == "v2"
    assert final["version"] == 2


def test_find_note_by_title_past_first_200(e2e_client: RobotNotesClient):
    """https://github.com/cedricziel/robot-notes/issues/239 is fixed: the
    client's `_find_note_by_title_scan` fallback now follows `next_cursor`
    instead of only ever fetching the first page. This also exercises the
    fast path added by #259 (a server-side `title` filter) since
    `find_note_by_title` tries that first — the fallback scan only runs if
    the server rejects the filter, so this test still proves the pagination
    fix as long as an unfiltered `path` listing lands the target note past
    the first page, whichever path the client took to find it."""
    path = f"e2e-pagination-{_uid()}"
    target_title = f"e2e-target-{_uid()}"

    # 201 filler notes so the target (the 202nd note in this folder) is
    # guaranteed to land past the first page (limit=200, sorted by id
    # ascending == creation order).
    for i in range(201):
        e2e_client.create_note(title=f"e2e-filler-{i:04d}-{_uid()}", content="x", path=path)

    e2e_client.create_note(title=target_title, content="the one we're looking for", path=path)

    found = e2e_client.find_note_by_title(target_title, path=path)

    assert found is not None
    assert found["title"] == target_title
