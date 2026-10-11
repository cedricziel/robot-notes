import json
from time import perf_counter
from uuid import uuid4

import pytest
from robot_notes import RobotNotesProvider

pytestmark = pytest.mark.e2e


def test_scoped_expansion_recovers_tail_evidence_under_budget(
    tmp_path, monkeypatch, e2e_base_url, e2e_api_key, e2e_client
):
    query = "checkpoint" + uuid4().hex
    scope = "quality/" + query
    expected = "The recovery approver is Morgan."
    relevant = e2e_client.create_note(
        title="Recovery evidence",
        path=scope,
        content="Routine output. " * 4000 + query + ". " + "filler " * 30 + expected,
    )
    unrelated = e2e_client.create_note(
        title="Other project", path=scope + "-other", content=query + " unrelated"
    )
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", e2e_api_key)
    providers = []
    try:
        results = {}
        for name, options in (
            ("baseline", {}),
            (
                "bounded",
                {
                    "recall_path": scope,
                    "recall_max_bytes": 1400,
                    "recall_expand_chars": 1000,
                },
            ),
        ):
            home = tmp_path / name
            home.mkdir()
            (home / "robot_notes.json").write_text(
                json.dumps({"base_url": e2e_base_url, **options})
            )
            provider = RobotNotesProvider()
            providers.append(provider)
            provider.initialize(name, hermes_home=str(home))
            started = perf_counter()
            context = provider.prefetch(query)
            results[name] = {
                "context": context,
                "latency_ms": (perf_counter() - started) * 1000,
                "context_bytes": len(context.encode("utf-8")),
            }
        assert expected not in results["baseline"]["context"]
        assert unrelated["id"] in results["baseline"]["context"]
        assert expected in results["bounded"]["context"]
        assert relevant["id"] in results["bounded"]["context"]
        assert relevant["updated_at"] in results["bounded"]["context"]
        assert unrelated["id"] not in results["bounded"]["context"]
        assert results["bounded"]["context_bytes"] <= 1400
        print(
            json.dumps(
                {
                    name: {
                        key: value for key, value in result.items() if key != "context"
                    }
                    for name, result in results.items()
                }
            )
        )
    finally:
        for provider in providers:
            provider.shutdown()
        e2e_client.delete_note(relevant["id"])
        e2e_client.delete_note(unrelated["id"])
