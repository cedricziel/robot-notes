import pytest

from robot_notes.memory_corrections import plan_memory_edit


def test_previous_content_selects_exact_entry_when_search_text_is_ambiguous():
    plan = plan_memory_edit(
        "color blue\ncolor green",
        "replace",
        "color red",
        {"old_text": "color", "previous_content": "color blue"},
    )
    assert plan.content == "color red\ncolor green"
    assert plan.state == "changed"


def test_multiline_previous_content_replaces_entire_entry():
    plan = plan_memory_edit(
        "head\nprofile:\ncolor blue\nsize small\ntail",
        "replace",
        "profile:\ncolor red\nsize large",
        {"previous_content": "profile:\ncolor blue\nsize small"},
    )
    assert plan.content == "head\nprofile:\ncolor red\nsize large\ntail"


def test_multiline_remove_preserves_neighboring_entries():
    plan = plan_memory_edit(
        "head\nprofile:\ncolor blue\nsize small\ntail",
        "remove",
        "",
        {"previous_content": "profile:\ncolor blue\nsize small"},
    )
    assert plan.content == "head\ntail"


def test_ambiguous_fallback_does_not_append_new_active_claim():
    plan = plan_memory_edit(
        "color blue\ncolor green", "replace", "color red", {"old_text": "color"}
    )
    assert plan.content is None
    assert plan.state == "needs_review"
    assert plan.reason == "ambiguous_selector"


def test_unmatched_replacement_does_not_append_new_active_claim():
    plan = plan_memory_edit("color blue", "replace", "color red", {"old_text": "size"})
    assert plan.content is None
    assert plan.state == "needs_review"
    assert plan.reason == "missing_previous_entry"


def test_previous_content_is_not_reinterpreted_as_a_substring():
    plan = plan_memory_edit(
        "color blue and green",
        "replace",
        "color red",
        {"old_text": "color", "previous_content": "color blue"},
    )
    assert plan.content is None
    assert plan.reason == "missing_previous_entry"


def test_explicit_multiline_selector_is_replaced_as_one_span():
    plan = plan_memory_edit(
        "head\ncolor blue\nsize small\ntail",
        "replace",
        "color red",
        {"old_text": "color blue\nsize small"},
    )
    assert plan.content == "head\ncolor red\ntail"


def test_repeated_multiline_add_does_not_duplicate_a_complete_entry():
    plan = plan_memory_edit(
        "head\ncolor blue\nsize small\ntail", "add", "color blue\nsize small"
    )
    assert plan.content is None
    assert plan.state == "unchanged"


def test_repeated_replacement_with_previous_entry_already_removed_is_unchanged():
    plan = plan_memory_edit(
        "color red\ntail", "replace", "color red", {"previous_content": "color blue"}
    )
    assert plan.content is None
    assert plan.state == "unchanged"


def test_duplicate_exact_entries_do_not_leave_a_superseded_copy_active():
    plan = plan_memory_edit(
        "color blue\ntail\ncolor blue",
        "replace",
        "color red",
        {"previous_content": "color blue"},
    )
    assert plan.content == "color red\ntail\ncolor red"


def test_remove_without_metadata_uses_legacy_complete_content():
    plan = plan_memory_edit("color blue\ntail", "remove", "color blue")
    assert plan.content == "tail"


@pytest.mark.parametrize(
    "metadata", [{"previous_content": []}, {"previous_content": ""}]
)
def test_invalid_exact_metadata_does_not_fall_back_to_weaker_selector(metadata):
    plan = plan_memory_edit(
        "color blue", "replace", "color red", {**metadata, "old_text": "color"}
    )
    assert plan.content is None
    assert plan.reason == "invalid_previous_content"


def test_overlapping_multiline_matches_require_review():
    plan = plan_memory_edit("a\na\na", "replace", "b", {"previous_content": "a\na"})
    assert plan.content is None
    assert plan.reason == "ambiguous_selector"


def test_empty_replacement_does_not_remove_the_previous_entry():
    plan = plan_memory_edit(
        "color blue", "replace", "", {"previous_content": "color blue"}
    )
    assert plan.content is None
    assert plan.reason == "empty_replacement"


def test_add_preserves_legacy_deduplication_of_outer_entry_whitespace():
    assert plan_memory_edit('likes coffee ', 'add', 'likes coffee').state == 'unchanged'
