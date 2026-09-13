## Context

`SearchIndex` (`server/lib/src/search_index.dart`) owns a single SQLite database at `<data-dir>/search.db`, opened via the native `sqlite3` FFI binding (real libsqlite3, so it can load runtime extensions). It maintains `notes_fts` (FTS5), `link_edges`, and a `meta` table carrying `schema_version` (currently `kSearchSchemaVersion = 3`); a mismatch triggers a full rebuild from `<data-dir>/content/**/*.md` on startup. Config is resolved once at startup in `Config.fromArgs` (`server/lib/src/config.dart`), CLI flag or `ROBOT_NOTES_*` env var, frozen for the process lifetime. See `proposal.md` for why hybrid search is needed and `specs/search/spec.md` for the resulting requirements.

## Goals / Non-Goals

**Goals:**

- Add vector storage and KNN query capability to the existing `search.db` without a second database file or a second startup-rebuild code path.
- Keep `SearchIndex.search()` the single call site MCP and REST both use; fusion logic lives there, not duplicated in `routes/search.dart` and `mcp/tools.dart`.
- Make the embedding provider swappable and absent-by-default, so existing deployments see zero behavior change until they opt in.

**Non-Goals:**

- Implementing the in-process ONNX-FFI adapter (tracked separately, per proposal's Non-goals).
- Tuning RRF's `k` constant or the BM25/vector candidate-set sizes for retrieval quality — ship a documented default, revisit empirically later.
- A management UI or CLI subcommand for triggering/monitoring backfill — it runs automatically and logs progress, matching how index rebuild already behaves.

## Decisions

**Vector extension: `sqlite_vector` (pub.dev) over manually loading `asg017/sqlite-vec`.** `sqlite_vector` is a maintained Dart package (verified publisher) that ships prebuilt binaries per platform and a `loadSqliteVectorExtension()` call, rather than us vendoring `asg017/sqlite-vec`'s shared libraries and wiring `SqliteExtension.inLibrary` by hand. Since our only consumer is this Dart server (no cross-language ecosystem benefit to `sqlite-vec`'s wider adoption), the ready-made package's lower integration risk wins.

**Confirmed API shape (spike, task 4.1) — corrects the `vec0`-virtual-table assumption above.** `sqlite_vector` does _not_ use an `asg017/sqlite-vec`-style `vec0` virtual table. Instead:

- `sqlite3.loadSqliteVectorExtension()` is called once per process, before opening any database (registers the extension's native functions globally).
- The embedding lives in a plain `BLOB` column on an ordinary table — a new `note_vectors(id TEXT PRIMARY KEY, embedding BLOB)` table, keyed by note id, sitting alongside `notes_fts`/`link_edges` rather than a column on the FTS5 table itself (FTS5 columns aren't a fit for a raw vector blob). It's populated via the scalar function `vector_as_f32('[<comma-separated floats>]')` (a JSON-array-string literal, not a bound `List<double>`).
- **`vector_init('<table>', '<column>', 'type=FLOAT32,dimension=<N>')` must be re-run on every new connection/process** — confirmed by spike: it registers in-memory metadata for that connection, not a persistent on-disk index, so a closed-and-reopened database (e.g. after a server restart) fails `vector_full_scan` with "unable to retrieve context" until `vector_init` runs again. It's idempotent within a connection (calling it twice does not error), so `SearchIndex._initSchema` can call it unconditionally on every `open()`.
- KNN query is a table-valued function joined by `rowid`: `SELECT e.<pk>, v.distance FROM <table> AS e JOIN vector_full_scan('<table>', '<column>', vector_as_f32('[...]'), <k>) AS v ON e.rowid = v.rowid ORDER BY v.distance`. Confirmed well-behaved for `k` larger than the row count (returns all available rows, no error) and for a zero-row table (returns zero results, no error) — both matter for a freshly-created or freshly-emptied vault.
- Fallback, if `sqlite_vector` proves unsuitable at a later stage (e.g. a missing platform binary in production, or the native-asset build-hook toolchain misbehaving outside this spike's environment): fall back to manually loading `asg017/sqlite-vec` via `SqliteExtension.inLibrary`, which the earlier research confirmed has prebuilt macOS/Linux binaries and a `vec0` virtual-table shape — the spec's "vector table with KNN" requirement doesn't care which extension backs it, only that groups 4–7's public behavior (dimension-sized storage, KNN ordering) holds.

**Ranking fusion: Reciprocal Rank Fusion, not score blending.** `score(note) = Σ 1/(k + rank_r(note))` over each ranker `r` (BM25, vector KNN) that returned the note at all, with the standard `k = 60`. RRF only needs each ranker's _rank position_, not its score, so it sidesteps normalizing BM25's unbounded negative range against cosine's `[-1, 1]` — the reason it was picked over a weighted blend in the original discussion. Candidate sets: top 50 from FTS5 and top 50 from vector KNN, unioned before fusion, then truncated to the caller's `limit`. A note appearing in only one ranker's results still gets a (weaker) fused score, so keyword-only or vector-only matches aren't dropped.

**Fused `rank` field:** the existing `SearchHit.rank` (`double`, lower = more relevant) is preserved as a comparable ordering value for the _current_ result set — computed as `-fusedScore` when fusion runs, or the underlying `bm25()` value when it doesn't. It's not meant to be comparable across requests or ranking modes; nothing today persists or compares `rank` outside a single response.

**Embedding computation: awaited by the caller, before the write transaction, best-effort.** Revised during implementation (group 5): rather than making `SearchIndex.upsert()` itself `async` — which would force every existing call site, including ~13 synchronous test call sites that don't care about embeddings, to add `await` — `upsert()` stays synchronous and gains an optional `embedding` parameter (`List<double>?`). `NoteWriteService.create()`/`update()` (already `async`, the sole production caller) call and await `embedOrNull(embeddingProvider, content, logger: ...)` _before_ calling `upsert()`, then pass the result through. This preserves the same observable behavior the spec requires — computed before the write commits, included in the same transaction as the FTS/link-edge update, never blocking or failing the write on provider failure — while keeping the async boundary at the layer that was already async. `upsert()` writes the embedding (when non-null) into `note_vectors` inside its existing transaction; when `embedding` is omitted or the caller had no provider configured, the transaction proceeds exactly as before. The note is queryable via BM25 immediately regardless, and picked up by backfill later if its embedding is still missing.

**Backfill: a startup-triggered background loop, not a synchronous startup step.** On startup, after `SearchIndex` is ready, if a provider is configured the server starts a detached async loop that queries for note ids present in `notes_fts` but absent from the vector table, computes embeddings in small batches (e.g. 10 at a time with a short delay between batches to avoid saturating a local Ollama instance), and stops when caught up. It re-runs opportunistically (e.g. every startup) since it's a cheap no-op once caught up. This reuses the same `content/**/*.md` scan machinery as index rebuild for the "index missing/corrupt" case, but as a lighter incremental pass when only embeddings are missing.

**Query-time embedding generation:** `SearchIndex.search()` calls `EmbeddingProvider.embed(query)` once per request when a provider is configured, in parallel with (not after) the FTS5 query, to avoid adding the embedding call's latency on top of the keyword query's.

**Config surface:** `--embedding-provider` / `ROBOT_NOTES_EMBEDDING_PROVIDER` (only `ollama` supported initially), `--ollama-base-url` / `ROBOT_NOTES_OLLAMA_BASE_URL` (default `http://localhost:11434`), `--ollama-embedding-model` / `ROBOT_NOTES_OLLAMA_MODEL` (default `nomic-embed-text`) — added to `Config` alongside the existing OIDC/OTel optional-group pattern in `config.dart`.

**Schema version bump:** `kSearchSchemaVersion` moves 3 → 4 (adds the vector table), triggering the existing rebuild-on-mismatch path for any pre-existing `search.db`. No separate migration path is needed — rebuild-from-content already exists and is cheap enough at homelab scale.

## Risks / Trade-offs

- **[Risk]** `sqlite_vector`'s extension might not expose exactly the `vec0`-style syntax assumed here, or might lack a needed platform build → **Mitigation:** decision above already names the manual `asg017/sqlite-vec` load as a fallback; validate the chosen package's actual API during the first implementation task before committing to its call shape elsewhere.
- **[Risk]** Backfill racing a large vault against a slow local Ollama instance could take a long time to converge → **Mitigation:** batched with delay, runs in the background, and search correctness never depends on it finishing (BM25 always available).
- **[Risk]** RRF's fixed `k = 60` and 50-candidate cutoff are unvalidated defaults, not tuned against real note content → **Mitigation:** explicitly a Non-Goal to tune now; both are named constants, trivial to adjust later without a schema or API change.
- **[Trade-off]** Every note write now does a synchronous-in-the-transaction embedding call when a provider is configured, adding provider latency to writes → accepted because it keeps embeddings consistent with FTS/link-edge updates at the same commit point, and it degrades to "no embedding, write still succeeds" rather than blocking.
