"""Evaluate synthetic evidence through the real server and Hermes prefetch."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import tempfile
import time
from contextlib import closing
from pathlib import Path
from urllib.parse import urlparse

from robot_notes import RobotNotesProvider
from robot_notes.client import RobotNotesClient

CORPUS = Path(__file__).with_name("corpus.json")
BASELINE = Path(__file__).with_name("keyword_baseline.json")


def score(context, notes, evidence, stale):
    passages = dict(
        re.findall(r"\(id: ([^,]+), [^)]*\): (.*?)(?=\n- |$)", context, re.DOTALL)
    )
    returned = set(passages)
    relevant = {notes[key] for key in evidence}
    stale_ids = {notes[key] for key in stale}
    recovered = sum(
        text in passages.get(notes[key], "") for key, text in evidence.items()
    )
    return {
        "evidence_recall": recovered / len(evidence),
        "irrelevant_count": len(returned - relevant - stale_ids),
        "stale_count": len(returned & stale_ids),
        "retrieved_count": len(returned),
        "context_bytes": len(context.encode("utf-8")),
    }


def wait_for_vectors(database, ids):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        with closing(
            sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True)
        ) as db:
            indexed = {row[0] for row in db.execute("SELECT id FROM note_vectors")}
        if set(ids.values()) <= indexed:
            return
        time.sleep(0.1)
    raise TimeoutError("Synthetic note embeddings did not finish within 60 seconds")


def evaluate(base_url, api_key, corpus, *, embedding_database=None):
    if urlparse(base_url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("Evaluation requires a throwaway loopback server")
    results = []
    with tempfile.TemporaryDirectory(prefix="robot-notes-quality-") as home:
        Path(home, "robot_notes.json").write_text(
            json.dumps(
                {
                    "base_url": base_url,
                    "actor": "synthetic-alice",
                }
            )
        )
        previous_key = os.environ.get("ROBOT_NOTES_API_KEY")
        os.environ["ROBOT_NOTES_API_KEY"] = api_key
        provider = RobotNotesProvider()
        client = RobotNotesClient(
            base_url=base_url, api_key=api_key, actor="synthetic-fixture"
        )
        try:
            if client.list_notes()["items"]:
                raise ValueError("Evaluation requires an empty throwaway vault")
            provider.initialize("synthetic-quality", hermes_home=home)
            for scenario in corpus:
                ids = {}
                try:
                    for note in scenario["notes"]:
                        content = (
                            note.get("padding", "") * note.get("repeat", 0)
                            + note["content"]
                        )
                        created = client.create_note(
                            title=note["key"],
                            content=content,
                            path=note.get("path", "quality"),
                        )
                        ids[note["key"]] = created["id"]
                    if embedding_database is not None:
                        wait_for_vectors(embedding_database, ids)
                    client.search(scenario["query"], limit=5)
                    started = time.perf_counter()
                    context = provider.prefetch(
                        scenario["query"], session_id=scenario["name"]
                    )
                    elapsed_ms = (time.perf_counter() - started) * 1000
                    result = score(
                        context, ids, scenario["evidence"], scenario.get("stale", [])
                    )
                    results.append(
                        {
                            "scenario": scenario["name"],
                            **result,
                            "latency_ms": elapsed_ms,
                        }
                    )
                finally:
                    for note_id in ids.values():
                        client.delete_note(note_id)
        finally:
            provider.shutdown()
            client.close()
            if previous_key is None:
                os.environ.pop("ROBOT_NOTES_API_KEY", None)
            else:
                os.environ["ROBOT_NOTES_API_KEY"] = previous_key
    return results


def regressions(results, baseline):
    failures = []
    if {result["scenario"] for result in results} != set(baseline):
        failures.append("Scenario names differ from baseline")
    for result in results:
        expected = baseline.get(result["scenario"])
        if expected is None:
            continue
        for metric in (
            "evidence_recall",
            "irrelevant_count",
            "stale_count",
            "retrieved_count",
        ):
            if result[metric] != expected[metric]:
                failures.append(
                    f"{result['scenario']}: {metric} expected {expected[metric]}, got {result[metric]}"
                )
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--search-db", type=Path, required=True)
    parser.add_argument("--embedding-manifest", type=Path)
    args = parser.parse_args()
    manifest = (
        json.loads(args.embedding_manifest.read_text())
        if args.embedding_manifest
        else None
    )
    if manifest is not None and not all(
        manifest.get(key)
        for key in ("provider", "model", "model_digest", "provider_version", "settings")
    ):
        parser.error(
            "Embedding manifest requires provider, model, model_digest, provider_version, and settings"
        )
    with closing(
        sqlite3.connect(f"{args.search_db.resolve().as_uri()}?mode=ro", uri=True)
    ) as db:
        hybrid = (
            db.execute(
                "SELECT 1 FROM sqlite_master WHERE name = 'note_vectors'"
            ).fetchone()
            is not None
        )
    if hybrid != (manifest is not None):
        parser.error("Server vector table and embedding manifest disagree")
    corpus_bytes = CORPUS.read_bytes()
    results = evaluate(
        os.environ["ROBOT_NOTES_E2E_BASE_URL"],
        os.environ["ROBOT_NOTES_E2E_API_KEY"],
        json.loads(corpus_bytes),
        embedding_database=args.search_db if hybrid else None,
    )
    failures = [] if hybrid else regressions(results, json.loads(BASELINE.read_text()))
    report = {
        "schema_version": 1,
        "mode": "hybrid" if hybrid else "keyword-only",
        "embedding_manifest": manifest,
        "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(),
        "results": results,
        "baseline_differences": failures,
        "target_gaps": [
            row["scenario"]
            for row in results
            if row["evidence_recall"] < 1
            or row["irrelevant_count"]
            or row["stale_count"]
        ],
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(bool(failures))


if __name__ == "__main__":
    main()
