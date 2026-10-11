import hashlib

from robot_notes.correction_proposals import compile_block_edit, source_references


def accepted(body, spans):
    note = {"id": "note", "version": 7, "content": body}
    blocks = []
    for number, (start, end) in enumerate(spans):
        text = body[start:end]
        blocks.append(
            {
                "id": f"b{number}",
                "revision": number + 1,
                "kind": "paragraph",
                "start": len(body[:start].encode("utf-16-le")) // 2,
                "end": len(body[:end].encode("utf-16-le")) // 2,
                "hash": hashlib.sha256(text.encode()).hexdigest(),
            }
        )
    mapping = {
        "id": "note",
        "version": 7,
        "content_hash": hashlib.sha256(body.encode()).hexdigest(),
        "offset_encoding": "utf-16",
        "blocks": blocks,
        "ambiguous_ids": [],
    }
    return note, mapping


def test_replacement_uses_real_utf16_span_and_preserves_gap_and_neighbor():
    note, mapping = accepted("🦾 blue\n\nkeep", [(0, 6), (8, 12)])
    plan = compile_block_edit(note, mapping, "🦾 red\n\nkeep")
    assert plan.state == "proposable"
    assert plan.operations == [
        {
            "type": "replace",
            "block_id": "b0",
            "expected_revision": 1,
            "text": "🦾 red",
            "supersedes": [
                {
                    "kind": "block_revision",
                    "note_id": "note",
                    "version": 7,
                    "block_id": "b0",
                    "block_revision": 1,
                }
            ],
        }
    ]


def test_terminal_gap_append_uses_exact_last_anchor():
    note, mapping = accepted("head\n\n", [(0, 4)])
    plan = compile_block_edit(note, mapping, "head\n\nnew")
    assert plan.operations == [
        {
            "type": "insert_after",
            "block_id": "b0",
            "expected_revision": 1,
            "text": "new",
        }
    ]


def test_whitespace_only_document_insertion_has_no_fabricated_anchor():
    note, mapping = accepted("\n\n", [])
    plan = compile_block_edit(note, mapping, "\n\nnew")
    assert plan.operations == [
        {
            "type": "insert_after",
            "block_id": None,
            "expected_revision": None,
            "text": "new",
        }
    ]


def test_complete_block_deletion_does_not_delete_untouched_separators():
    note, mapping = accepted("blue\n\nkeep", [(0, 4), (6, 10)])
    plan = compile_block_edit(note, mapping, "\n\nkeep")
    assert plan.operations == [
        {"type": "delete", "block_id": "b0", "expected_revision": 1}
    ]


def test_gap_edit_requires_review_instead_of_a_guessed_operation():
    note, mapping = accepted("blue\n\nkeep", [(0, 4), (6, 10)])
    plan = compile_block_edit(note, mapping, "keep")
    assert plan.state == "needs_review"
    assert plan.operations == []


def test_stale_map_and_ambiguous_identity_are_not_guessed():
    note, mapping = accepted("blue", [(0, 4)])
    mapping["version"] = 6
    assert compile_block_edit(note, mapping, "red").reason == "block_map_stale"
    mapping["version"] = 7
    mapping["ambiguous_ids"] = ["b0"]
    assert compile_block_edit(note, mapping, "red").reason == "ambiguous_block"


def test_lineage_keeps_only_real_raw_host_identifiers():
    assert source_references(
        {
            "session_id": "host-session",
            "turn_id": "host-turn",
            "tool_call_id": "call",
            "task_id": "task",
            "previous_content": "old",
            "approved": True,
        }
    ) == [
        {
            "kind": "conversation",
            "session_id": "host-session",
            "turn_id": "host-turn",
            "tool_call_id": "call",
            "task_id": "task",
        }
    ]


def test_missing_lineage_is_explicit_unknown_without_latest_session_guess():
    assert source_references({"old_text": "old", "tool_call_id": "call"}) == [
        {"kind": "unknown", "reason": "source_not_recorded"}
    ]


def test_archive_reference_uses_only_the_explicit_supplied_digest():
    digest = "a" * 64
    assert source_references(
        {"evidence_refs": [{"kind": "archive", "digest": digest}]}
    ) == [{"kind": "archive", "digest": digest}]


def test_malformed_utf16_boundary_and_body_hash_require_review():
    note, mapping = accepted("🦾 blue", [(0, 6)])
    mapping["blocks"][0]["start"] = 1
    assert compile_block_edit(note, mapping, "🦾 red").state == "needs_review"
    note, mapping = accepted("blue", [(0, 4)])
    note["content"] = "green"
    assert compile_block_edit(note, mapping, "red").reason == "block_map_stale"


def test_two_changed_blocks_keep_the_untouched_gap():
    note, mapping = accepted("blue\n\nsmall", [(0, 4), (6, 11)])
    plan = compile_block_edit(note, mapping, "red\n\nlarge")
    assert plan.state == "proposable"
    assert [(op["block_id"], op["text"]) for op in plan.operations] == [
        ("b0", "red"),
        ("b1", "large"),
    ]


def test_source_authority_and_cross_vault_fields_are_rejected():
    import pytest

    for reference in [
        {"kind": "archive", "digest": "a" * 64, "verified": True},
        {"kind": "note_revision", "note_id": "note", "version": True},
        {
            "kind": "block_revision",
            "note_id": "note",
            "version": 1,
            "block_id": "b",
            "block_revision": 1,
            "vault_id": "other",
        },
    ]:
        with pytest.raises(ValueError):
            source_references({"evidence_refs": [reference]})
