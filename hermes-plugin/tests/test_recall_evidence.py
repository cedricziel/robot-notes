from robot_notes.recall_evidence import evidence_context, narrow_paths, passage


def test_expansion_recovers_tail_evidence_around_search_snippet():
    content = (
        "Earlier routine output. " * 3000
        + "Recovery phrase is saffron telescope. Keep it offline."
    )
    result = passage(
        content, "…Recovery phrase is <mark>saffron</mark> telescope.", 120
    )
    assert "saffron telescope. Keep it offline." in result
    assert len(result) <= 120


def test_budget_counts_metadata_and_utf8_without_splitting_characters():
    items = [
        {
            "id": "1",
            "title": "Tea",
            "snippet": "茶" * 400,
            "updated_at": "2026-10-11T00:00:00Z",
        }
    ]
    context, count = evidence_context(items, max_bytes=180, expand_chars=0)
    assert len(context.encode("utf-8")) <= 180
    assert "updated: 2026-10-11T00:00:00Z" in context
    assert "id: 1" in context
    assert "茶" in context
    assert count == 1


def test_no_partial_source_header_when_budget_too_small():
    items = [{"id": "1", "title": "Long title" * 100, "snippet": "evidence"}]
    assert evidence_context(items, max_bytes=80, expand_chars=0) == ("", 0)


def test_expansion_uses_fetched_content_and_freshness():
    items = [
        {
            "id": "1",
            "title": "Old title",
            "snippet": "<mark>saffron</mark>",
            "updated_at": "old",
        }
    ]
    note = {
        "id": "1",
        "title": "Current title",
        "content": "saffron telescope",
        "updated_at": "new",
    }
    context, count = evidence_context(
        items, max_bytes=500, expand_chars=100, load_note=lambda _: note
    )
    assert "Current title" in context
    assert "saffron telescope" in context
    assert "updated: new" in context
    assert "Old title" not in context
    assert count == 1


def test_task_scope_intersects_identity_roots_without_widening():
    assert narrow_paths(("people/alice", "agents/helper"), "people") == (
        "people/alice",
    )
    assert narrow_paths(("people/alice",), "people/bob") == ()
    assert narrow_paths((None,), "projects/launch") == ("projects/launch",)


def test_unicode_case_matching_keeps_original_character_offsets():
    assert "SAFFRON telescope" in passage(
        "ß" * 100 + "SAFFRON telescope", "<mark>saffron</mark>", 30
    )


def test_note_moved_outside_scope_is_not_injected_after_expansion():
    items = [{"id": "1", "title": "Moved", "snippet": "evidence"}]
    note = {"title": "Moved", "path": "people/bob", "content": "evidence"}
    assert evidence_context(
        items,
        max_bytes=500,
        expand_chars=100,
        load_note=lambda _: note,
        recall_paths=("people/alice",),
    ) == ("", 0)
