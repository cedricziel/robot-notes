"""Measure synthetic tail evidence through production search and public prefetch."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from statistics import median
from urllib.parse import urlparse

import httpx
from robot_notes import RobotNotesProvider
from robot_notes.client import RobotNotesClient

CORPUS = Path(__file__).with_name("corpus.json")
MODEL = "nomic-embed-text:v1.5"
DIGEST = "0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f"
PROVIDER_VERSION = "0.40.3"
TOKENIZER_SHA256 = "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"
TOKENIZER_REVISION = "e9b6763023c676ca8431644204f50c2b100d9aab"
SCOPE = "synthetic/current"
KEY = "synthetic-experiment-key-not-a-secret"


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def materialize(scenario):
    body = scenario["padding"] * scenario["repeat"] + "\n\n" + scenario["evidence"]
    return [
        {"label": "current", "content": body, "path": SCOPE},
        {"label": "superseded", "content": scenario["stale"], "path": SCOPE},
        {
            "label": "other_scope",
            "content": scenario["evidence"],
            "path": SCOPE + "-other",
        },
        *(
            {"label": f"decoy_{i}", "content": text, "path": SCOPE}
            for i, text in enumerate(scenario["decoys"])
        ),
    ]


def measure(context, ids, evidence, token_count):
    passages = dict(
        re.findall(r"\(id: ([^,]+), [^)]*\): (.*?)(?=\n- |$)", context, re.DOTALL)
    )
    returned = {label for label, note_id in ids.items() if note_id in passages}
    return {
        "source_recall": int("current" in returned),
        "evidence_recall": int(evidence in passages.get(ids["current"], "")),
        "stale_count": int("superseded" in returned),
        "irrelevant_count": len(returned - {"current", "superseded"}),
        "retrieved_count": len(returned),
        "retrieved_labels": sorted(returned),
        "context_bytes": len(context.encode()),
        "injected_tokens": token_count(context),
        "injected_context": context,
        "source_ids": ids,
    }


@contextmanager
def metered_embeddings(ollama_url, token_count):
    records = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            started = time.perf_counter()
            response = httpx.post(ollama_url + self.path, json=payload, timeout=120)
            result = response.json()
            value = payload.get("input", "")
            with lock:
                records.append(
                    {
                        "input_chars": len(value),
                        "input_tokens": token_count(value),
                        "prompt_eval_count": result.get("prompt_eval_count"),
                        "latency_ms": (time.perf_counter() - started) * 1000,
                        "status": response.status_code,
                    }
                )
            self.send_response(response.status_code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(response.content)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", records
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@contextmanager
def server_process(binary, directory, embedding_url=None):
    port = free_port()
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("ROBOT_NOTES_", "OTEL_", "OIDC_"))
    }
    env.update(
        ROBOT_NOTES_API_KEY=KEY,
        ROBOT_NOTES_DATA_DIR=str(directory),
        ROBOT_NOTES_PORT=str(port),
    )
    if embedding_url:
        env.update(
            ROBOT_NOTES_EMBEDDING_PROVIDER="ollama",
            ROBOT_NOTES_OLLAMA_BASE_URL=embedding_url,
            ROBOT_NOTES_OLLAMA_MODEL=MODEL,
        )
    with (directory / "server.log").open("w") as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            url = f"http://127.0.0.1:{port}"
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError(
                        "Synthetic server failed; inspect its task-owned log"
                    )
                try:
                    if httpx.get(url + "/healthz").is_success:
                        break
                except httpx.TransportError:
                    pass
                time.sleep(0.1)
            else:
                raise TimeoutError("Synthetic server startup timed out")
            yield url
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def wait_vectors(database, ids):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        with sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True) as db:
            found = {row[0] for row in db.execute("SELECT id FROM note_vectors")}
        if set(ids.values()) <= found:
            return
        time.sleep(0.1)
    raise TimeoutError("Indexing did not finish; do not report query timings")


def run_mode(mode, binary, directory, corpus, token_count, embedding_url, records):
    results = []
    with server_process(
        binary, directory, embedding_url if mode == "whole_note_hybrid" else None
    ) as url:
        client = RobotNotesClient(base_url=url, api_key=KEY, actor="synthetic-fixture")
        if client.list_notes()["items"]:
            raise ValueError("Experiment requires an empty disposable vault")
        home = directory / "hermes"
        home.mkdir()
        (home / "robot_notes.json").write_text(
            json.dumps({"base_url": url, "recall_path": SCOPE})
        )
        old_key = os.environ.get("ROBOT_NOTES_API_KEY")
        os.environ["ROBOT_NOTES_API_KEY"] = KEY
        provider = RobotNotesProvider()
        try:
            provider.initialize("synthetic-experiment", hermes_home=str(home))
            for scenario in corpus:
                ids = {}
                records_start = len(records)
                started = time.perf_counter()
                for note in materialize(scenario):
                    created = client.create_note(
                        title=note["label"], content=note["content"], path=note["path"]
                    )
                    ids[note["label"]] = created["id"]
                if mode == "whole_note_hybrid":
                    wait_vectors(directory / "search.db", ids)
                index_ms = (time.perf_counter() - started) * 1000
                index_records = records[records_start:]
                client.search(scenario["query"], limit=5)
                latencies = []
                for _ in range(3):
                    started = time.perf_counter()
                    context = provider.prefetch(scenario["query"])
                    latencies.append((time.perf_counter() - started) * 1000)
                results.append(
                    {
                        "scenario": scenario["name"],
                        **measure(context, ids, scenario["evidence"], token_count),
                        "latency_ms": latencies,
                        "median_latency_ms": median(latencies),
                        "indexing_wall_ms": index_ms,
                        "index_embeddings": index_records,
                        "long_note_source_chars": len(
                            materialize(scenario)[0]["content"]
                        ),
                        "long_note_source_tokens": token_count(
                            "current\n\n" + materialize(scenario)[0]["content"]
                        ),
                        "evidence_offset_chars": materialize(scenario)[0][
                            "content"
                        ].index(scenario["evidence"]),
                    }
                )
                for note_id in ids.values():
                    client.delete_note(note_id)
        finally:
            provider.shutdown()
            client.close()
            if old_key is None:
                os.environ.pop("ROBOT_NOTES_API_KEY", None)
            else:
                os.environ["ROBOT_NOTES_API_KEY"] = old_key
    return results


def in_scope(path, scope):
    return path == scope or path.startswith(scope + "/")


def passage_context(candidates, client, *, scope, max_bytes):
    context = "Relevant notes from robot-notes:\n"
    seen = set()
    accepted = 0
    rejected = 0
    for row in candidates:
        if accepted >= 5 or len(seen) >= 10:
            break
        if row["id"] in seen or not in_scope(row["path"], scope):
            continue
        seen.add(row["id"])
        current = client.get_note(row["id"])
        if current["version"] != row["version"] or not in_scope(current["path"], scope):
            rejected += 1
            continue
        source = (
            f"- {current['title']} (id: {row['id']}, {current['path']}, "
            f"updated: {current['updated_at']}, version: {row['version']}): "
        )
        remaining = max_bytes - len((context + source + "\n").encode())
        text = row["text"].encode()[: max(0, remaining)].decode(errors="ignore")
        if not text:
            continue
        context += source + text + "\n"
        accepted += 1
    return (context.rstrip() if accepted else ""), rejected


def split_passages(content, tokenizer, *, size=400, overlap=80):
    offsets = tokenizer.encode(content, add_special_tokens=False).offsets
    if not offsets:
        return []
    if math.ceil(len(offsets) / (size - overlap)) > 128:
        raise ValueError("Prototype refuses more than 128 passages per note")
    result = []
    for start in range(0, len(offsets), size - overlap):
        end = min(start + size, len(offsets))
        result.append(content[offsets[start][0] : offsets[end - 1][1]])
        if end == len(offsets):
            break
    return result


def cosine(left, right):
    return sum(a * b for a, b in zip(left, right)) / (
        math.sqrt(sum(a * a for a in left)) * math.sqrt(sum(b * b for b in right))
    )


class PassagePrototype:
    def __init__(self, notes, tokenizer, embedding_url):
        self.rows = []
        self.embedding_url = embedding_url
        self.db = sqlite3.connect(":memory:")
        self.db.execute("CREATE VIRTUAL TABLE passages USING fts5(title, text)")
        for note in notes:
            for text in split_passages(note["content"], tokenizer):
                self.rows.append(
                    {
                        **note,
                        "text": text,
                        "vector": self.embed(note["title"] + "\n\n" + text),
                    }
                )
                self.db.execute(
                    "INSERT INTO passages(rowid,title,text) VALUES(?,?,?)",
                    (len(self.rows), note["title"], text),
                )

    def embed(self, text):
        response = httpx.post(
            self.embedding_url + "/api/embed",
            json={
                "model": MODEL,
                "input": text,
                "truncate": False,
                "options": {"num_ctx": 2048},
            },
            timeout=120,
        )
        response.raise_for_status()
        vector = response.json()["embeddings"][0]
        if len(vector) != 768 or not all(math.isfinite(value) for value in vector):
            raise ValueError("Invalid real-model vector")
        return vector

    def search(self, query, client):
        vector = self.embed(query)
        vector_order = sorted(
            range(len(self.rows)),
            key=lambda i: cosine(vector, self.rows[i]["vector"]),
            reverse=True,
        )[:50]
        try:
            lexical = self.db.execute(
                "SELECT rowid FROM passages WHERE passages MATCH ? ORDER BY bm25(passages) LIMIT 50",
                (query,),
            ).fetchall()
        except sqlite3.OperationalError:
            sanitized = re.sub(r"[^\w\s]", " ", query)
            lexical = self.db.execute(
                "SELECT rowid FROM passages WHERE passages MATCH ? ORDER BY bm25(passages) LIMIT 50",
                (sanitized,),
            ).fetchall()
        scores = {}
        for order in ([row[0] - 1 for row in lexical], vector_order):
            for rank, index in enumerate(order, 1):
                scores[index] = scores.get(index, 0) + 1 / (60 + rank)
        candidates = [
            self.rows[i] for i in sorted(scores, key=scores.get, reverse=True)
        ]
        return passage_context(candidates, client, scope=SCOPE, max_bytes=4096)


def run_prototype(
    binary, directory, corpus, tokenizer, token_count, embedding_url, records
):
    results = []
    with server_process(binary, directory) as url:
        client = RobotNotesClient(base_url=url, api_key=KEY, actor="synthetic-fixture")
        try:
            for scenario in corpus:
                ids = {}
                notes = []
                for note in materialize(scenario):
                    created = client.create_note(
                        title=note["label"], content=note["content"], path=note["path"]
                    )
                    ids[note["label"]] = created["id"]
                    full = client.get_note(created["id"])
                    if in_scope(full["path"], SCOPE):
                        notes.append(full)
                records_start = len(records)
                started = time.perf_counter()
                prototype = PassagePrototype(notes, tokenizer, embedding_url)
                index_ms = (time.perf_counter() - started) * 1000
                index_records = records[records_start:]
                prototype.search(scenario["query"], client)
                latencies = []
                for _ in range(3):
                    started = time.perf_counter()
                    context, rejected = prototype.search(scenario["query"], client)
                    latencies.append((time.perf_counter() - started) * 1000)
                current = client.get_note(ids["current"])
                client.update_note(
                    current["id"],
                    version=current["version"],
                    content=current["content"] + "\nFreshness probe.",
                )
                after_change, rejected = passage_context(
                    [row for row in prototype.rows if row["id"] == ids["current"]],
                    client,
                    scope=SCOPE,
                    max_bytes=4096,
                )
                if after_change or rejected != 1:
                    raise AssertionError(
                        "Prototype exposed an obsolete passage after a note revision"
                    )
                results.append(
                    {
                        "scenario": scenario["name"],
                        **measure(context, ids, scenario["evidence"], token_count),
                        "latency_ms": latencies,
                        "median_latency_ms": median(latencies),
                        "indexing_wall_ms": index_ms,
                        "index_embeddings": index_records,
                        "passage_count": len(prototype.rows),
                        "freshness_probe_rejected": rejected,
                    }
                )
                prototype.db.close()
                for note_id in ids.values():
                    client.delete_note(note_id)
        finally:
            client.close()
    return results


def main():
    from tokenizers import Tokenizer
    import tokenizers

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-binary", type=Path, required=True)
    parser.add_argument("--server-source-revision", required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--ollama-url", default="http://127.0.0.1:11439")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--passage-prototype", action="store_true")
    args = parser.parse_args()
    if urlparse(args.ollama_url).hostname not in {"127.0.0.1", "localhost", "::1"}:
        parser.error("Use an isolated loopback Ollama instance")
    actual = httpx.get(args.ollama_url + "/api/tags").json()
    model = next(row for row in actual["models"] if row["name"] == MODEL)
    if model["digest"] != DIGEST:
        parser.error("Model digest differs from the pinned experiment")
    provider_version = httpx.get(args.ollama_url + "/api/version").json()["version"]
    if provider_version != PROVIDER_VERSION or tokenizers.__version__ != "0.22.2":
        parser.error("Provider or tokenizer library differs from the pinned versions")
    if hashlib.sha256(args.tokenizer.read_bytes()).hexdigest() != TOKENIZER_SHA256:
        parser.error("Tokenizer differs from the pinned public artifact")
    if not re.fullmatch(r"[a-f0-9]{40}", args.server_source_revision):
        parser.error("Server source revision must be an exact Git SHA")
    import robot_notes

    provider_root = Path(robot_notes.__file__).resolve().parents[2]
    provider_revision = subprocess.check_output(
        ["git", "-C", str(provider_root), "rev-parse", "HEAD"], text=True
    ).strip()
    tokenizer = Tokenizer.from_file(str(args.tokenizer))

    def token_count(text):
        return len(tokenizer.encode(text, add_special_tokens=False).ids)

    corpus_bytes = CORPUS.read_bytes()
    report = {
        "schema_version": 1,
        "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(),
        "embedding_manifest": {
            "provider": "ollama",
            "model": MODEL,
            "model_digest": DIGEST,
            "provider_version": provider_version,
            "settings": {
                "dimensions": 768,
                "num_ctx": 2048,
                "truncate": True,
                "max_input_chars": 8192,
            },
        },
        "tokenizer": {
            "name": "nomic-ai/nomic-embed-text-v1.5",
            "revision": TOKENIZER_REVISION,
            "sha256": hashlib.sha256(args.tokenizer.read_bytes()).hexdigest(),
            "library": "tokenizers",
            "library_version": tokenizers.__version__,
            "add_special_tokens": False,
        },
        "scope": SCOPE,
        "server_source_revision": args.server_source_revision,
        "server_binary_sha256": hashlib.sha256(
            args.server_binary.read_bytes()
        ).hexdigest(),
        "provider_source_revision": provider_revision,
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "runs": {},
    }
    with tempfile.TemporaryDirectory(prefix="robot-notes-semantic-tail-") as scratch:
        with metered_embeddings(args.ollama_url, token_count) as (
            embedding_url,
            records,
        ):
            probe = "x " * 4096
            probe_response = httpx.post(
                embedding_url + "/api/embed",
                json={
                    "model": MODEL,
                    "input": probe,
                    "truncate": True,
                    "options": {"num_ctx": 2048},
                },
                timeout=120,
            )
            probe_response.raise_for_status()
            report["model_sequence_cutoff_probe"] = {
                "synthetic_input": "x-space repeated 4096 times",
                **records[-1],
            }
            for mode in ("keyword_only", "whole_note_hybrid"):
                directory = Path(scratch) / mode
                directory.mkdir()
                report["runs"][mode] = run_mode(
                    mode,
                    args.server_binary.resolve(),
                    directory,
                    json.loads(corpus_bytes),
                    token_count,
                    embedding_url,
                    records,
                )
            if args.passage_prototype:
                if not any(
                    row["evidence_recall"] < 1
                    for row in report["runs"]["whole_note_hybrid"]
                ):
                    raise ValueError("No measured recall gap justifies the prototype")
                directory = Path(scratch) / "passage_prototype"
                directory.mkdir()
                report["runs"]["passage_prototype"] = run_prototype(
                    args.server_binary.resolve(),
                    directory,
                    json.loads(corpus_bytes),
                    tokenizer,
                    token_count,
                    embedding_url,
                    records,
                )
                report["prototype_settings"] = {
                    "passage_tokens": 400,
                    "overlap_tokens": 80,
                    "max_passages_per_note": 128,
                    "fusion_k": 60,
                    "ranker_candidates": 50,
                    "max_notes": 5,
                    "max_source_reads": 10,
                    "context_max_bytes": 4096,
                }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            {
                mode: [
                    {
                        key: row[key]
                        for key in (
                            "scenario",
                            "evidence_recall",
                            "stale_count",
                            "irrelevant_count",
                            "injected_tokens",
                            "median_latency_ms",
                        )
                    }
                    for row in rows
                ]
                for mode, rows in report["runs"].items()
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
