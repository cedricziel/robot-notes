## Why

Search today is BM25-over-FTS5 only: a query must share literal (stemmed) words with a note or it finds nothing. An agent asking "what did we decide about auth last month" gets no results if the note says "OAuth" and never the word "decide." Semantic recall alongside the existing keyword search closes this gap without giving up the FTS5 path's speed, exactness, or its role as the always-available fallback.

## What Changes

- Add a `vec0` virtual table (via a loadable SQLite vector extension) to `search.db`, storing one embedding per note alongside the existing `notes_fts` table.
- Add an `EmbeddingProvider` adapter interface (`embed(text) -> Future<List<double>>`, `dimensions`) decoupling embedding generation from storage/ranking. Ship one adapter: an Ollama HTTP client (`nomic-embed-text`, 768-dim) configured via `ROBOT_NOTES_EMBEDDING_PROVIDER` / `ROBOT_NOTES_OLLAMA_BASE_URL` / `ROBOT_NOTES_OLLAMA_MODEL`, following the project's existing `ROBOT_NOTES_*` config convention.
- When an embedding provider is configured, `GET /search` and the `search_notes` MCP tool SHALL fuse BM25 results with vector KNN results via Reciprocal Rank Fusion (RRF) instead of BM25 rank alone.
- When no embedding provider is configured, or the configured provider is unreachable, search SHALL fall back to today's BM25-only behavior — semantic search is additive, never a hard dependency.
- Every note write (create/update/append) that already updates the FTS index SHALL also (re)compute and store that note's embedding, when a provider is configured.
- On startup, if a provider is configured and notes exist without a stored embedding (new provider, or notes written before one was configured), the server SHALL backfill them asynchronously without blocking startup.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `search`: index schema gains an optional vector table; ranking becomes RRF(BM25, vector KNN) when embeddings are available, unchanged BM25-only otherwise; index rebuild/write-path requirements extend to cover the embedding column; new requirements for provider configuration and graceful degradation.

## Impact

- `server/lib/src/search_index.dart`: extend `SearchIndex` (schema version bump, vec0 table, RRF fusion, backfill).
- `server/routes/search.dart`, `server/lib/src/mcp/tools.dart`: no response-shape change — same `items`/`rank` contract, ranking source changes underneath.
- New `server/lib/src/embeddings/` package: `EmbeddingProvider` interface + Ollama adapter.
- New runtime dependency: a loadable SQLite vector extension binary (bundled for macOS/Linux), loaded via the existing `sqlite3` FFI binding.
- Optional runtime dependency: a reachable Ollama instance — absence must not break search.

## Non-goals

- No in-process CPU embedding (hand-rolled ONNX Runtime FFI bindings) in this change — tracked as separate follow-up work; the adapter interface only needs to leave room for it.
- No new/changed `search_notes` MCP tool schema — same inputs/outputs, ranking changes are internal.
- No per-actor or per-tenant embedding scoping — single shared index, same trust model as today's search.
- No embedding model choice beyond the one Ollama adapter (`nomic-embed-text`) — no multi-model or configurable-dimension support yet.
