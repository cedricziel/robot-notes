# Evaluate memory retrieval

Run the evaluation against a fresh, disposable local server with embeddings disabled.
Use a separate data directory and port, synthetic credentials, and no telemetry exporter.
Install the plugin's development dependencies, then run from `hermes-plugin`:

```sh
export ROBOT_NOTES_E2E_BASE_URL=http://127.0.0.1:18350
export ROBOT_NOTES_E2E_API_KEY=quality-test-key
python -m evaluations.memory_quality \
	--search-db /tmp/robot-notes-quality-data/search.db \
	--output /tmp/memory-quality.json
```

The runner rejects remote hosts and nonempty vaults. It uses a temporary Hermes
configuration, creates each scenario's notes, calls public `prefetch()`, and deletes
only the notes it created. Shut down the disposable server and remove its data
after the run. Do not point this runner at a personal server, even if its vault is empty.

CI runs this command before the existing e2e tests and uploads `memory-quality.json`.
The server's search database must belong to that same server. The runner checks
whether the vector table exists to prevent silently measuring a hybrid server as
keyword-only.

## Interpret the report

All fixtures are synthetic. Ordinary stored notes represent accepted knowledge;
the suite does not implement or evaluate proposal approval. The long-note fixture
is a generated conversation exceeding 50 KiB, with evidence at its tail.

Evidence recall is the fraction of expected supporting notes whose injected
passage contains the required evidence text. Merely returning the note ID does
not count. Irrelevant count measures returned notes outside the relevant and stale
sets. Stale count measures returned notes explicitly marked superseded in the
fixture. Counts use unique IDs from the actual injected text, with a maximum of
five results under the current provider. Each scenario has one supporting note.

The report records elapsed milliseconds for one synchronous prefetch after a
successful search probe, plus the UTF-8 byte count of the injected text. The probe
checks for server errors that the provider might otherwise hide as empty recall.
These timings describe warm search, not first-request or background-prefetch
latency. Bytes are not model tokens. Neither timing nor byte count is a CI gate.

The checked-in keyword baseline records current behavior:

| Scenario | Evidence recall | Irrelevant | Stale | Target gap |
| --- | ---: | ---: | ---: | --- |
| Paraphrase | 0 | 0 | 0 | Recover car evidence for automobile |
| Long-note tail | 1 | 0 | 0 | None for exact keyword retrieval |
| Correction | 1 | 0 | 1 | Exclude the superseded destination |
| Irrelevant notes | 1 | 0 | 0 | None for unrelated vocabulary |
| Identity scope | 1 | 1 | 0 | Exclude Bob's preference for Alice |

The ideal target for every scenario is recall 1 with zero stale or irrelevant
results. Identity scope measures personal recall intent within one shared vault,
not authorization or vault isolation. The corpus is a small regression sample,
not evidence of general retrieval quality or conversational task success.

Any change to the four baseline metrics fails CI, including an improvement.
Review the report before updating `keyword_baseline.json`. Do not lower expectations
merely to make CI pass. The corpus SHA-256 in each report identifies fixture changes.

## Run an embedding comparison

Start a separate disposable server with an explicitly selected embedding provider
and model. Pin the provider version and model digest, and record the actual server
configuration in a JSON file with these fields:

```json
{
  "provider": "ollama",
  "provider_version": "<installed version>",
  "model": "<configured model name>",
  "model_digest": "<immutable model digest>",
  "settings": {"dimensions": "<configured dimensions>"}
}
```

Add `--embedding-manifest /path/to/manifest.json` to the command. The manifest is
operator-supplied metadata, not server attestation. Never include credentials.
The runner waits up to 60 seconds for every scenario note's vector to exist before
searching. Failed or incomplete indexing fails the run. Hybrid results are reported
without comparison to the keyword baseline. Compare runs with identical corpus,
provider, model digest, and settings. CI does not download a model or run embeddings.
