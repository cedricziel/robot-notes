## 1. Embedding provider adapter interface

- [x] 1.1 Write a failing test asserting an `EmbeddingProvider` abstract interface exists at `server/lib/src/embeddings/embedding_provider.dart` with `Future<List<double>> embed(String text)` and an `int dimensions` getter; implement the interface to pass
- [x] 1.2 Write a failing test for a `NoopEmbeddingProvider` (or equivalent "unconfigured" sentinel) that is never constructed by the config path when no provider is selected, asserting `SearchIndex` treats "no provider" as a distinct state from "provider configured but erroring"; implement to pass — implemented as a nullable `EmbeddingProvider?` (design.md's chosen approach, not a Noop class) plus an `embedOrNull()` helper that collapses "absent" and "erroring" to the same `null` result while logging only the error case

## 2. Ollama embedding adapter

- [x] 2.1 Write a failing test asserting `OllamaEmbeddingProvider.embed(text)` POSTs `{"model": ..., "prompt": text}` to `<baseUrl>/api/embeddings` and returns the `embedding` array from the response, using an injected/mocked HTTP client; implement `server/lib/src/embeddings/ollama_embedding_provider.dart` to pass
- [x] 2.2 Write a failing test asserting `embed()` throws a typed `EmbeddingProviderException` (not a raw HTTP/socket exception) on a network error, timeout, or non-2xx response; implement to pass
- [x] 2.3 Write a failing test asserting `dimensions` matches the configured model's known output size (768 for `nomic-embed-text`); implement to pass

## 3. Config surface

- [x] 3.1 Write a failing test asserting `Config.fromArgs` resolves `embeddingProvider` from `--embedding-provider` / `ROBOT_NOTES_EMBEDDING_PROVIDER` (only `ollama` accepted, anything else throws `ConfigError`), `null` when unset; implement in `server/lib/src/config.dart` to pass
- [x] 3.2 Write a failing test asserting `ollamaBaseUrl` defaults to `http://localhost:11434` and `ollamaEmbeddingModel` defaults to `nomic-embed-text`, both overridable via `--ollama-base-url`/`ROBOT_NOTES_OLLAMA_BASE_URL` and `--ollama-embedding-model`/`ROBOT_NOTES_OLLAMA_MODEL`; implement to pass
- [x] 3.3 Wire `Config` → an `EmbeddingProvider?` factory (returns `null` when `embeddingProvider` is unset) used at server startup, and verify via a startup-level test that no `EmbeddingProvider` is constructed when unconfigured — `embeddingProviderFromConfig()` added at `server/lib/src/embeddings/embedding_provider_factory.dart`; actual call-site wiring into `AppDeps.bootstrap`/`SearchIndex.open` deferred to task 8.1 since `SearchIndex` doesn't accept a provider until task 4.2

## 4. Vector storage in the search index

- [x] 4.1 Spike: confirm `sqlite_vector`'s actual Dart API (`loadSqliteVectorExtension()` call shape, virtual table DDL, KNN query syntax) against the running `sqlite3` connection in `search_index.dart`; record the confirmed API shape in a code comment at the call site if it differs from `design.md`'s assumption (fall back to manually loading `asg017/sqlite-vec` per `design.md` if `sqlite_vector` doesn't fit) — no `vec0` virtual table; it's `loadSqliteVectorExtension()` once per process + a plain BLOB column + `vector_init(table, column, 'type=FLOAT32,dimension=N')` re-run on every connection open (idempotent, in-memory only) + `vector_full_scan(...)` joined on `rowid`. `sqlite_vector` added to `server/pubspec.yaml`; `design.md` updated with the confirmed shape
- [x] 4.2 Write a failing test asserting `SearchIndex` creates a vector table sized to the configured `EmbeddingProvider.dimensions` when a provider is supplied at construction, and does not create it when no provider is supplied; implement in `search_index.dart` to pass — table is `note_vectors(id TEXT PRIMARY KEY, embedding BLOB)`, sized via `vector_init`
- [x] 4.3 Bump `kSearchSchemaVersion` 3 → 4 and write a failing test asserting a `search.db` with `schema_version = 3` is treated as mismatched and rebuilt on startup; implement to pass
- [x] 4.4 Write a failing test asserting a KNN query against the vector table with a query embedding and `k` returns up to `k` note ids ordered by ascending distance; implement the query method to pass — `SearchIndex.vectorSearch()`, `@visibleForTesting` (not yet wired into `search()`, that's group 6)

## 5. Write-path: compute and store embeddings

- [x] 5.1 Write a failing test asserting `SearchIndex.upsert()` awaits `EmbeddingProvider.embed(content)` before opening its write transaction and stores the result in the vector table keyed by note id, when a provider is configured; implement to pass — per the design.md revision, the `embedOrNull()` await happens in `NoteWriteService.create()`/`update()` (already `async`) _before_ calling `upsert()`, which stays synchronous and gained an `embedding` parameter; this avoided forcing `await` onto ~13 pre-existing synchronous `upsert()` call sites in tests that don't care about embeddings. Covered by both a `SearchIndex`-level test (embedding stored when supplied) and a `NoteWriteService`-level test (embedding computed and passed through end-to-end)
- [x] 5.2 Write a failing test asserting `upsert()` still commits the FTS/link-edge update (write succeeds) when `embed()` throws `EmbeddingProviderException`, leaving no vector-table row for that note; implement to pass
- [x] 5.3 Write a failing test asserting deleting a note removes its vector-table row alongside its `notes_fts` and `link_edges` rows; implement to pass
- [x] 5.4 Write a failing test asserting `upsert()` does not call `embed()` at all when no provider is configured (no behavior change from today); implement/verify to pass

## 6. Query-path: RRF fusion

- [x] 6.1 Write a failing test asserting `SearchIndex.search()` returns BM25-only-ordered results, unchanged from current behavior, when no provider is configured; implement/verify to pass (regression guard before touching ranking) — also required making `search()` itself `async` (mechanical refactor, separate commit, ~40 call-site updates across 2 test files + both production callers, zero behavior change, full suite green before layering fusion on top)
- [x] 6.2 Write a failing test asserting `SearchIndex.search()` computes the query embedding and the FTS5 query concurrently (not sequentially) when a provider is configured, using a fake `EmbeddingProvider` with an instrumented delay; implement to pass — scaled back from a timing-based test (flaky, and BM25's near-zero cost means wall-clock barely differs concurrent vs. sequential either way) to a deterministic test asserting the provider is invoked; the actual concurrency (kick off `embedOrNull()` before running the synchronous BM25 query, await it after) is a code-structure property verified by inspection, matching this project's stance against flaky timing assertions
- [x] 6.3 Write a failing test asserting fused results apply RRF (`k = 60`) over the top-50 BM25 and top-50 vector candidate sets, including a note present in only one candidate set; implement the fusion function to pass — `SearchIndex._fuse()`
- [x] 6.4 Write a failing test asserting a note with no keyword overlap but high vector similarity to the query is returned when a provider is configured (the semantic-recall scenario from the spec); implement/verify end-to-end to pass
- [x] 6.5 Write a failing test asserting `search()` falls back to BM25-only ordering (no error, HTTP 200 / no tool error) when the configured provider's `embed()` throws at query time; implement to pass

## 7. Startup backfill

- [ ] 7.1 Write a failing test asserting a backfill pass identifies note ids present in `notes_fts` but absent from the vector table; implement the query to pass
- [ ] 7.2 Write a failing test asserting backfill processes ids in batches (e.g. 10) with a delay between batches rather than all at once, using a fake provider and a batch-call counter; implement to pass
- [ ] 7.3 Write a failing test asserting server startup returns/becomes ready before backfill completes (backfill runs detached, not awaited in the startup path); implement to pass
- [ ] 7.4 Write a failing test asserting a note with a pending (not-yet-backfilled) embedding is still returned via BM25 matching; implement/verify to pass

## 8. Wiring and docs

- [ ] 8.1 Wire the `EmbeddingProvider?` built in task 3.3 into `SearchIndex` construction at server startup (`server/lib/src/...` entrypoint) and into the backfill trigger from task 7.3
- [ ] 8.2 Update `server/README.md` (or the relevant ops doc) documenting the new `--embedding-provider`/`ROBOT_NOTES_EMBEDDING_PROVIDER` flags, the Ollama prerequisite, and that search works identically without them
- [ ] 8.3 Run `dart analyze` and the full `server` test suite; fix any warnings introduced by this change

## Definition of Done

- [ ] Full `server` test suite passes, covering every scenario in `openspec/changes/add-hybrid-search/specs/search/spec.md`.
- [ ] Search behavior is byte-for-byte unchanged (same ranking, same response shape) when no embedding provider is configured — verified by the regression test in 6.1.
- [ ] `GET /search` and the `search_notes` MCP tool never return an error or 5xx solely because the embedding provider is absent or unreachable.
- [ ] Every commit is atomic and conventional (`feat(search): ...`, `test(search): ...`), each preceded by a failing test.
- [ ] `dart analyze` is clean and `/simplify` has been run over the diff before the final commit.
- [ ] `openspec validate add-hybrid-search --strict` passes before archiving.
