# Semantic tail recall experiment

The bounded passage prototype recovers the three paraphrased tail passages that
current whole-note hybrid recall does not inject. Do not roll out this prototype: indexing
work and injected tokens increase, and superseded and irrelevant sources remain.
The result supports further passage experiments; three synthetic questions do not
establish general retrieval quality or make passage indexing universally unsuitable.

## Recorded run

[result.json](result.json) records source IDs, synthetic injected contexts, per-request
embedding input and evaluated token counts, index completion, three warm query
timings, source revisions, executable and runner hashes, and the embedding manifest.
The fixture is [corpus.json](corpus.json), SHA-256
`0c279d3d54fc8627f3106ca3bf58004f55affbed5640cc690fb2cf8ace6b4da4`.

| Paraphrased tail query | Keyword evidence | Whole-note evidence | Passage evidence | Whole-note injected tokens | Passage injected tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| Restoration authority | 0 | 0 | 1 | 209 | 432 |
| Erasure deadline | 0 | 0 | 1 | 219 | 582 |
| Network repair | 0 | 0 | 1 | 224 | 445 |

Evidence counts only when the expected sentence appears in the injected passage
for the current source ID. A returned source ID or a copy from another folder does
not count. Whole-note hybrid returned the current source ID in all three tail cases (source-note
recall 3/3) while injecting none of the required sentences (evidence recall 0/3).
This identifies a passage localization and context assembly gap; it does not show
failure to retrieve relevant source notes. Embedding truncation is measured separately
and this comparison does not isolate it as the cause of the injection gap.

Both hybrid modes return one explicitly superseded source and three
irrelevant sources for each question. The untruncated paraphrase control succeeds
with whole-note hybrid and passage recall, while keyword recall remains empty.
All modes use the same folder scope and source labels.

Whole-note query medians were 24.8–29.2 ms for the tail cases; passage medians were
34.2–37.6 ms. Whole-note indexing used seven embeddings per scenario and completed
in 393–548 ms. Passage indexing used 20–24 embeddings and completed in 1215–1504 ms.
The production index embeds all seven source notes before applying query scope;
the prototype indexes six in-scope notes. Baseline injection uses default server snippets; the prototype uses up to 400-token
passages and a 4096-byte total context. The prototype therefore changes passage
localization and formatting/context size as well as its temporary index. The recall
gain cannot be attributed solely to persistent passage indexing. Compare matched
formatting and budgets, including context assembly from already retrieved source
notes, before deciding whether a persistent index is needed.

The prototype indexes serially in Python,
while production background indexing can overlap requests. Timings include the
local metering proxy and are observations from one warm run, not performance gates.

Long notes contain 4577–6015 tokens under the named tokenizer. Evidence begins at
characters 26882–30962, beyond the provider's 8192-character input cap. The first
restoration prefix contains 1391 tokenizer tokens; Ollama evaluates 1393 including
its special tokens. That fixture loses its tail before reaching the model's 2048-token
limit. A separate 8192-character `x ` probe contains 4096 tokenizer tokens and
produces `prompt_eval_count: 2048`, demonstrating the independent model cutoff.
The report retains every indexing request's counts so other fixtures can be checked.

Injected token counts use the Nomic WordPiece tokenizer without special tokens,
including source metadata and IDs. They are actual counts under that named tokenizer,
not Hermes chat-model billing or context costs; a different chat tokenizer can differ.
Random note IDs also make exact counts vary slightly between runs. This experiment
does not show token savings.

## Prototype boundary

The prototype is confined to this evaluation. It uses 400-token passages with
80-token overlap, at most 128 passages per note, real 768-dimensional embeddings,
50 candidates per ranker, reciprocal rank fusion with `k=60`, five unique notes,
up to ten current-source reads, and a 4096-byte injected context limit. It retains
source IDs and revisions, checks current revisions and folder scope before injection,
and rejects an obsolete passage in a real post-index note-update probe.

Revision freshness prevents an old vector from representing a changed note. It does
not infer whether a still-existing note's claim has been superseded. The unchanged
stale-source result requires knowledge/proposal policy or retrieval work beyond this
prototype. No accepted knowledge, proposal approval, or production index changes are
part of this experiment.

## Reproduce

Use an isolated loopback Ollama instance and the public model; the runner creates
and removes disposable vaults itself. It strips Robot Notes, OIDC, and telemetry
settings from child-server environments and uses an explicit synthetic key. It never
reads production conversation data or production model caches.

The recorded server source is `f279ac1b910c9aeab671129b4b9f6e5f5e3c1aa7` and the
provider source is `1f9d64d784dc344d87e5d1b4301eae2f48e0765e` (scoped recall).
Check out those exact commits in separate local directories. Build the server with
`dart pub get`, `cd server && dart pub global run dart_frog_cli:dart_frog build`,
change the generated `build/bin/server.dart` address to `InternetAddress.loopbackIPv4`,
then run `cd build && dart pub get && dart build cli -o out`. Use the installed Dart
and Dart Frog toolchain recorded by the repository's build configuration.

Install evaluation-only dependencies in a virtual environment:

```sh
python -m pip install httpx tokenizers==0.22.2
mkdir -p /tmp/robot-notes-semantic-models
OLLAMA_HOST=127.0.0.1:11439 OLLAMA_MODELS=/tmp/robot-notes-semantic-models OLLAMA_NO_CLOUD=1 ollama serve
```

In another terminal, run:

```sh
OLLAMA_HOST=127.0.0.1:11439 ollama pull nomic-embed-text:v1.5
curl -fsSL https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/e9b6763023c676ca8431644204f50c2b100d9aab/tokenizer.json -o /tmp/robot-notes-tokenizer.json
PYTHONPATH=/path/to/pinned-provider/hermes-plugin python hermes-plugin/evaluations/semantic_tail/run.py \
  --server-binary /path/to/pinned-server/server/build/out/bundle/bin/server \
  --server-source-revision f279ac1b910c9aeab671129b4b9f6e5f5e3c1aa7 \
  --tokenizer /tmp/robot-notes-tokenizer.json \
  --output /tmp/robot-notes-semantic-result.json \
  --passage-prototype
```

The runner verifies Ollama `0.40.3`, model digest
`0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f`,
tokenizers `0.22.2`, and tokenizer SHA-256
`d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66`.
It waits for every production vector before timing queries and rejects a prototype
run when the measured whole-note baseline has no evidence recall gap. Stop the
task-owned Ollama process after the run. Models are public downloads of about 274 MB.

The model's registry metadata describes its 2K context and embedding capability;
see the [Ollama model page](https://ollama.com/library/nomic-embed-text) and the
[pinned tokenizer artifact](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/blob/e9b6763023c676ca8431644204f50c2b100d9aab/tokenizer.json).
Our configured limit and cutoff measurements above describe the actual requests.
Keyword CI stays model-independent; the scorer and prototype boundary tests require
no model download or tokenizer package.
