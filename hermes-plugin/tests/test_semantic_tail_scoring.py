import importlib.util
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "semantic_tail_run", Path(__file__).parents[1] / "evaluations/semantic_tail/run.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def test_evidence_from_another_note_does_not_count_as_current_source_recall():
    context = "Relevant notes from robot-notes:\n- Current (id: c, scope): unrelated head\n- Other (id: o, other): supporting fact"
    result = runner.measure(
        context, {"current": "c", "other_scope": "o"}, "supporting fact", lambda text: 5
    )
    assert result["evidence_recall"] == 0
    assert result["irrelevant_count"] == 1
    assert result["injected_tokens"] == 5


def test_exact_current_passage_counts_and_superseded_source_is_reported():
    context = "Relevant notes from robot-notes:\n- Current (id: c, scope, updated: now): supporting fact\n- Old (id: s, scope): old fact"
    result = runner.measure(
        context, {"current": "c", "superseded": "s"}, "supporting fact", lambda text: 8
    )
    assert result["evidence_recall"] == 1
    assert result["stale_count"] == 1
    assert result["irrelevant_count"] == 0


def test_passage_selection_preserves_scope_deduplicates_and_rejects_changed_revision():
    class Client:
        def get_note(self, note_id):
            return {
                "id": note_id,
                "version": 2 if note_id == "changed" else 1,
                "title": note_id,
                "path": runner.SCOPE,
                "updated_at": "now",
            }

    candidates = [
        {
            "id": "outside",
            "version": 1,
            "path": runner.SCOPE + "-other",
            "text": "private",
        },
        {"id": "changed", "version": 1, "path": runner.SCOPE, "text": "old"},
        {
            "id": "current",
            "version": 1,
            "path": runner.SCOPE,
            "text": "supporting fact",
        },
        {"id": "current", "version": 1, "path": runner.SCOPE, "text": "second passage"},
    ]
    context, rejected = runner.passage_context(
        candidates, Client(), scope=runner.SCOPE, max_bytes=4096
    )
    assert "supporting fact" in context
    assert "private" not in context
    assert "second passage" not in context
    assert "old" not in context
    assert context.count("(id: current,") == 1
    assert rejected == 1


def test_passage_context_obeys_total_utf8_budget():
    class Client:
        def get_note(self, note_id):
            return {
                "id": note_id,
                "version": 1,
                "title": "Evidence",
                "path": runner.SCOPE,
                "updated_at": "now",
            }

    context, rejected = runner.passage_context(
        [
            {"id": "current", "version": 1, "path": runner.SCOPE, "text": "🦾" * 100},
        ],
        Client(),
        scope=runner.SCOPE,
        max_bytes=150,
    )
    assert context
    assert len(context.encode()) <= 150
    assert rejected == 0


def test_returned_current_source_without_required_passage_has_source_recall_only():
    context = (
        "Relevant notes from robot-notes:\n- Current (id: c, scope): unrelated head"
    )
    result = runner.measure(
        context, {"current": "c"}, "supporting fact", lambda text: 5
    )
    assert result["source_recall"] == 1
    assert result["evidence_recall"] == 0
