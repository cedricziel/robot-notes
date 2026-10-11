from evaluations.memory_quality import regressions, score


def test_evidence_must_appear_in_its_supporting_note():
    context = "Relevant notes from robot-notes:\n- expected (id: 1, ): missing\n- other (id: 2, ): jasmine tea"
    result = score(
        context, {"expected": "1", "other": "2"}, {"expected": "jasmine tea"}, []
    )
    assert result["evidence_recall"] == 0
    assert result["irrelevant_count"] == 1


def test_stale_results_do_not_count_twice_as_irrelevant():
    context = "- old (id: 1, ): tea\n- current (id: 2, ): café"
    result = score(context, {"old": "1", "current": "2"}, {"current": "café"}, ["old"])
    assert result == {
        "evidence_recall": 1.0,
        "irrelevant_count": 0,
        "stale_count": 1,
        "retrieved_count": 2,
        "context_bytes": len(context.encode("utf-8")),
    }


def test_baseline_change_requires_review_even_when_quality_improves():
    actual = [
        {
            "scenario": "paraphrase",
            "evidence_recall": 1.0,
            "irrelevant_count": 0,
            "stale_count": 0,
            "retrieved_count": 1,
        }
    ]
    baseline = {
        "paraphrase": {
            "evidence_recall": 0.0,
            "irrelevant_count": 0,
            "stale_count": 0,
            "retrieved_count": 0,
        }
    }
    assert regressions(actual, baseline) == [
        "paraphrase: evidence_recall expected 0.0, got 1.0",
        "paraphrase: retrieved_count expected 0, got 1",
    ]


def test_missing_scenario_cannot_pass_the_baseline():
    assert regressions([], {"paraphrase": {}}) == [
        "Scenario names differ from baseline"
    ]
