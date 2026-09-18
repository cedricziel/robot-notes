import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_otel_api/flutter_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/excerpt.dart';
import 'package:server/src/links.dart';
import 'package:server/src/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

/// Schema version for the FTS5 search index. Bumping this constant forces a
/// rebuild on the next startup — useful when the index columns or tokenizer
/// configuration change in incompatible ways.
///
/// Bumped to 4 for the `note_vectors` table (hybrid search): any
/// pre-existing `search.db` reports schema_version 3 and is therefore
/// treated as mismatched and rebuilt, per the "old schema triggers a
/// rebuild" requirement.
///
/// Bumped to 5 for the `note_meta` and `note_properties` tables (database
/// property index, see `add-databases` design's "Property values live in
/// SQLite" decision): a pre-existing `search.db` at schema 4 is rebuilt so
/// the new tables get populated for every note.
const int kSearchSchemaVersion = 5;

/// Frontmatter keys that are server-interpreted rather than caller-owned
/// property values, per the `add-databases` design's "Frontmatter
/// serialization keeps key order" decision. Excluded from `note_meta`'s
/// `frontmatter_json` and from the `note_properties` EAV rows built from
/// `extra` — they describe the note's role as a database definition, not a
/// row's property values.
const Set<String> kServerInterpretedKeys = {
  'type',
  'tags',
  'source',
  'properties',
  'views',
};

/// Guards [SearchIndex._ensureVectorExtensionLoaded] so
/// `sqlite3.loadSqliteVectorExtension()` — a process-global registration,
/// not a per-database one — runs at most once per process, even though
/// tests open many [SearchIndex]s in the same process.
bool _vectorExtensionLoaded = false;

/// Hard ceiling on a search `limit`, shared by `GET /search` and the
/// `search_notes` MCP tool so both surfaces clamp/reject the same way.
const int kMaxSearchLimit = 100;

/// Result row returned by [SearchIndex.search].
@immutable
class SearchHit {
  /// Builds a result describing one matching note.
  const SearchHit({
    required this.id,
    required this.title,
    required this.path,
    required this.snippet,
    required this.rank,
    required this.updatedAt,
  });

  /// Note id (ULID).
  final String id;

  /// Note title at index time.
  final String title;

  /// Folder the note lives in at index time, matching [StoredNote.path].
  final String path;

  /// Highlighted excerpt of the matched content with `<mark>` markers, or
  /// a plain-text excerpt for a hit that matched only via vector
  /// similarity (no FTS5 match to highlight).
  final String snippet;

  /// Lower is more relevant. A raw `bm25()` value when hybrid ranking
  /// isn't active for this result set; `-`(RRF fused score) when it is —
  /// see [SearchIndex.search]. Comparable only within one response, never
  /// across requests or ranking modes.
  final double rank;

  /// The note's `updated_at` as of the last [SearchIndex.upsert].
  final DateTime updatedAt;

  /// Returns a copy with [rank] replaced — used by fusion to re-rank a
  /// hit that already carries full BM25-derived data (title/snippet/etc.)
  /// without hand-copying every field.
  SearchHit copyWith({double? rank}) => SearchHit(
        id: id,
        title: title,
        path: path,
        snippet: snippet,
        rank: rank ?? this.rank,
        updatedAt: updatedAt,
      );
}

/// One result row from [SearchIndex.vectorSearch]: a note id and its
/// distance to the query embedding (lower is more similar).
@immutable
class VectorHit {
  /// Creates a KNN result pairing a note [id] with its [distance].
  const VectorHit({required this.id, required this.distance});

  /// Note id (ULID), matching [SearchHit.id].
  final String id;

  /// Distance from the query embedding, as reported by
  /// `sqlite_vector`'s `vector_full_scan`. Lower is more similar.
  final double distance;
}

/// Raw note metadata read directly from `notes_fts`, used by fusion to
/// build a [SearchHit] for a note that matched only via vector similarity
/// (so has no FTS5 match to build a highlighted snippet from).
@immutable
class _NoteMeta {
  const _NoteMeta({
    required this.title,
    required this.path,
    required this.content,
    required this.updatedAt,
    required this.tags,
  });

  final String title;
  final String path;
  final String content;
  final DateTime updatedAt;

  /// Space-delimited, lowercased, space-padded — see [SearchIndex._encodeTags].
  final String tags;
}

/// One of a note's outgoing `[[wikilinks]]`, as recorded in the
/// `link_edges` table by [SearchIndex.upsert]. Mirrors `link_index.dart`'s
/// `LinkEdge`, but carries the resolution snapshot (`targetId`) computed by
/// the caller at write time — [SearchIndex] itself never resolves titles,
/// it only stores whatever resolution its caller (`NoteWriteService`, or
/// [SearchIndex]'s own startup rebuild) already computed.
@immutable
class SearchLinkEdge {
  /// Creates an edge to [targetTitle], optionally already resolved to
  /// [targetId].
  const SearchLinkEdge({required this.targetTitle, this.targetId});

  /// The linked note's title, exactly as parsed.
  final String targetTitle;

  /// The linked note's id, or `null` for a phantom link (no note currently
  /// carries [targetTitle]).
  final String? targetId;

  /// Whether this edge currently resolves to a note.
  bool get resolved => targetId != null;
}

/// One `note_meta` row flagged `is_definition = 1`, as returned by
/// [SearchIndex.definitionsSource] — enough for `DatabaseRegistry.rebuild`
/// (see the `databases` package, not part of this file) to reparse every
/// candidate definition without re-reading files from [Storage]. Not a full
/// [NoteSummary]: `note_meta` doesn't carry `version`, tag set, or excerpt,
/// so a caller that needs those looks them up separately (e.g. via
/// `MetaIndex`).
@immutable
class DefinitionSourceRow {
  /// Creates a definition candidate row.
  const DefinitionSourceRow({
    required this.id,
    required this.title,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
    required this.extra,
  });

  /// Note id (ULID).
  final String id;

  /// Note title at index time.
  final String title;

  /// Folder the note lives in at index time.
  final String path;

  /// First write time, in UTC.
  final DateTime createdAt;

  /// Most recent write time, in UTC.
  final DateTime updatedAt;

  /// The note's full frontmatter `extra` map, decoded from
  /// `note_meta.frontmatter_json` — including the server-interpreted keys
  /// (`type`, `source`, `properties`, `views`; not `tags`, which is
  /// indexed separately) a definition note needs to reparse. See
  /// [SearchIndex.upsert]'s `extra` parameter for what's written here.
  final Map<String, Object?> extra;
}

/// Thrown by [SearchIndex.search] when the supplied query string is not a
/// valid FTS5 expression. The HTTP layer maps this to a 400 with code
/// `invalid_query`.
@immutable
class InvalidSearchQueryException implements Exception {
  /// Creates an exception describing the bad query [original] and the
  /// [reason] returned by SQLite.
  const InvalidSearchQueryException({
    required this.original,
    required this.reason,
  });

  /// The query string that failed to parse.
  final String original;

  /// SQLite's error message.
  final String reason;

  @override
  String toString() => 'InvalidSearchQueryException($original): $reason';
}

/// FTS5-backed full-text search index.
///
/// The index is a *derived cache*: if the database file is missing,
/// corrupt (failed `PRAGMA integrity_check`), or has a stale schema
/// version, [SearchIndex.open] rebuilds it by scanning [Storage]. Each
/// note save/delete must call [upsert] / [delete] to keep the index in
/// sync.
class SearchIndex {
  SearchIndex._(this._db, this._log, this._tracer, this._embeddingProvider);

  final Database _db;
  final Logger _log;
  final Tracer _tracer;

  /// When non-null, hybrid ranking is active: [search] fuses BM25 with
  /// vector similarity, and [upsert] computes and stores an embedding per
  /// note. `null` (the default) means search behaves exactly as it did
  /// before hybrid search existed.
  final EmbeddingProvider? _embeddingProvider;
  late final PreparedStatement _upsertStmt = _db.prepare(
    'INSERT OR REPLACE INTO notes_fts '
    '(rowid, id, title, path, content, updated_at, tags) '
    'VALUES ((SELECT rowid FROM notes_fts WHERE id = ?1), '
    '?1, ?2, ?3, ?4, ?5, ?6);',
  );
  late final PreparedStatement _deleteStmt = _db.prepare(
    'DELETE FROM notes_fts WHERE id = ?1;',
  );
  late final PreparedStatement _deleteLinkEdgesStmt = _db.prepare(
    'DELETE FROM link_edges WHERE source_id = ?1;',
  );
  late final PreparedStatement _insertLinkEdgeStmt = _db.prepare(
    'INSERT INTO link_edges (source_id, target_title, target_id, resolved) '
    'VALUES (?1, ?2, ?3, ?4);',
  );

  /// Only ever prepared/executed when [_embeddingProvider] is non-null,
  /// since `note_vectors` only exists in that case (see [_initSchema]).
  late final PreparedStatement _upsertVectorStmt = _db.prepare(
    'INSERT OR REPLACE INTO note_vectors (id, embedding) '
    'VALUES (?, vector_as_f32(?));',
  );
  late final PreparedStatement _deleteVectorStmt = _db.prepare(
    'DELETE FROM note_vectors WHERE id = ?;',
  );

  late final PreparedStatement _upsertNoteMetaStmt = _db.prepare(
    'INSERT OR REPLACE INTO note_meta '
    '(note_id, title, path, created_at, updated_at, is_definition, '
    'frontmatter_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);',
  );
  late final PreparedStatement _deleteNoteMetaStmt = _db.prepare(
    'DELETE FROM note_meta WHERE note_id = ?1;',
  );
  late final PreparedStatement _deletePropertiesStmt = _db.prepare(
    'DELETE FROM note_properties WHERE note_id = ?1;',
  );
  late final PreparedStatement _insertPropertyStmt = _db.prepare(
    'INSERT INTO note_properties '
    '(note_id, key, ordinal, text_value, num_value, bool_value, '
    'date_value, day_value) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);',
  );

  /// The backfill [open] kicks off automatically when a provider is
  /// configured, kept around so callers (namely tests) can await its
  /// completion explicitly instead of relying on incidental timing. `null`
  /// when no provider is configured — backfill never runs in that case.
  @visibleForTesting
  Future<void>? pendingBackfill;

  /// Opens the index at [dbFile] (creating its parent directory if
  /// necessary). If the file is missing, corrupt, or schema-mismatched the
  /// index is rebuilt by scanning [storage].
  ///
  /// Operators can flip [forceRebuild] to drop the existing file regardless
  /// of state — useful for ops runbooks that want to reseed from disk.
  ///
  /// When [embeddingProvider] is supplied, hybrid ranking is enabled: a
  /// `note_vectors` table sized to its `dimensions` is created (if absent)
  /// and (re)initialized for this connection — `sqlite_vector`'s
  /// `vector_init` registers per-connection metadata, not a persistent
  /// index, so it must run on every `open()`, not just once at table
  /// creation. `null` (the default) leaves search exactly as it behaved
  /// before hybrid search existed, including not creating the table at all.
  ///
  /// When [embeddingProvider] is supplied, a backfill pass (see
  /// [backfillEmbeddings]) is kicked off automatically and detached unless
  /// [autoBackfill] is `false` — tests that want to drive
  /// [backfillEmbeddings] explicitly (to control batching/timing) set this
  /// to `false` to avoid a second, racing pass.
  static Future<SearchIndex> open({
    required File dbFile,
    required Storage storage,
    Logger? logger,
    Tracer? tracer,
    bool forceRebuild = false,
    EmbeddingProvider? embeddingProvider,
    bool autoBackfill = true,
  }) async {
    final log = logger ?? Logger('search_index');
    await dbFile.parent.create(recursive: true);

    var rebuild = forceRebuild;
    if (!dbFile.existsSync()) {
      log.info('search.db missing, rebuilding from storage');
      rebuild = true;
    } else if (rebuild) {
      log.info('search.db rebuild forced by caller');
      dbFile.deleteSync();
    } else if (!_isHealthy(dbFile, log: log)) {
      log.warning('search.db unhealthy, rebuilding');
      dbFile.deleteSync();
      rebuild = true;
    }

    if (embeddingProvider != null) _ensureVectorExtensionLoaded();
    final db = sqlite3.open(dbFile.path);
    _initSchema(db, dimensions: embeddingProvider?.dimensions);

    final index = SearchIndex._(
      db,
      log,
      tracer ?? const NoopTracer('search_index'),
      embeddingProvider,
    );
    if (rebuild) {
      final loaded = await index._rebuild(storage);
      log.info('search.db rebuilt with $loaded note(s)');
    }
    if (embeddingProvider != null && autoBackfill) {
      // Detached on purpose: startup must not block on backfill, per the
      // "server backfills embeddings ... without blocking startup"
      // requirement. `pendingBackfill` lets tests (and anything else that
      // cares) await it explicitly instead of relying on timing.
      index.pendingBackfill = index.backfillEmbeddings().catchError(
        (Object e, StackTrace st) {
          log.warning('Embedding backfill failed', e, st);
        },
      );
      unawaited(index.pendingBackfill);
    }
    return index;
  }

  /// Loads `sqlite_vector`'s native functions, process-wide, exactly once —
  /// `Sqlite3.loadSqliteVectorExtension` registers them for every
  /// subsequently opened database, so a second call would be redundant (and
  /// isn't guaranteed idempotent the way `vector_init` is).
  static void _ensureVectorExtensionLoaded() {
    if (_vectorExtensionLoaded) return;
    sqlite3.loadSqliteVectorExtension();
    _vectorExtensionLoaded = true;
  }

  /// Inserts or replaces a row for [id] with [title], [path], [content],
  /// [updatedAt], [tags], and its outgoing [links] — all four persisted
  /// stores (the FTS row, its path/tags columns, and the `link_edges`
  /// rows) are updated together inside one transaction, per the
  /// "updated ... transactionally" requirement.
  ///
  /// [path] and [tags] default to root/empty for callers (mostly tests)
  /// that only care about title/content search and don't populate a full
  /// note's derived metadata.
  ///
  /// [embedding], when supplied alongside a configured embedding provider,
  /// is written to `note_vectors` in the same transaction. Callers (namely
  /// `NoteWriteService`, already `async`) are expected to have awaited
  /// `EmbeddingProvider.embed(content)` *before* calling this synchronous
  /// method — `upsert` itself stays synchronous so callers that don't care
  /// about embeddings (most existing call sites) are unaffected. Omitting
  /// [embedding] (no provider, or the caller's embed attempt failed) leaves
  /// `note_vectors` untouched; the write still commits.
  ///
  /// [extra], [createdAt], and [isDefinition] feed the database property
  /// index (`note_meta` / `note_properties`, see the `add-databases`
  /// design's "Property values live in SQLite" decision). All three are
  /// optional so every pre-existing call site (which doesn't know about
  /// properties) keeps compiling and indexing unchanged: [extra] defaults
  /// to empty (no property rows, an empty `frontmatter_json`), [createdAt]
  /// defaults to [updatedAt], and [isDefinition] defaults to `false`.
  void upsert({
    required String id,
    required String title,
    required String content,
    required DateTime updatedAt,
    String path = '',
    Set<String> tags = const {},
    List<SearchLinkEdge> links = const [],
    List<double>? embedding,
    Map<String, Object?> extra = const {},
    DateTime? createdAt,
    bool isDefinition = false,
  }) {
    _db.execute('BEGIN');
    try {
      _upsertNoTx(
        id: id,
        title: title,
        path: path,
        content: content,
        updatedAt: updatedAt,
        tags: tags,
        links: links,
        embedding: embedding,
        extra: extra,
        createdAt: createdAt,
        isDefinition: isDefinition,
      );
      // A provider is configured but this write's embed attempt failed
      // (or the caller never had content to embed): drop any vector left
      // over from a previous, successful write rather than serving stale
      // vector-search results for the note's now-changed content. Backfill
      // (see [backfillEmbeddings]) picks the id back up on its next pass
      // since it's now absent from `note_vectors`.
      if (_embeddingProvider != null && embedding == null) {
        _deleteVectorStmt.execute([id]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Core of [upsert], without its own transaction — used directly by
  /// [_rebuild], which wraps the whole rebuild (every note) in a single
  /// outer transaction instead of one per note; SQLite does not support
  /// nested `BEGIN`s.
  void _upsertNoTx({
    required String id,
    required String title,
    required String path,
    required String content,
    required DateTime updatedAt,
    required Set<String> tags,
    required List<SearchLinkEdge> links,
    List<double>? embedding,
    Map<String, Object?> extra = const {},
    DateTime? createdAt,
    bool isDefinition = false,
  }) {
    _upsertStmt.execute([
      id,
      title,
      path,
      content,
      updatedAt.toUtc().toIso8601String(),
      _encodeTags(tags),
    ]);
    _deleteLinkEdgesStmt.execute([id]);
    for (final link in links) {
      final resolvedFlag = link.resolved ? 1 : 0;
      _insertLinkEdgeStmt.execute([
        id,
        link.targetTitle,
        link.targetId,
        resolvedFlag,
      ]);
    }
    if (_embeddingProvider != null && embedding != null) {
      _upsertVectorStmt.execute([id, _encodeVector(embedding)]);
    }
    _upsertPropertyIndex(
      id: id,
      title: title,
      path: path,
      createdAt: createdAt ?? updatedAt,
      updatedAt: updatedAt,
      tags: tags,
      extra: extra,
      isDefinition: isDefinition,
    );
  }

  /// Writes [id]'s `note_meta` row (`frontmatter_json` holding the note's
  /// full `extra` map, including server-interpreted keys, so
  /// [definitionsSource] can hand a definition note's `source`/
  /// `properties`/`views` back to `DatabaseRegistry.rebuild` without a file
  /// read) and rebuilds its `note_properties` EAV rows from [extra] (with
  /// [kServerInterpretedKeys] excluded — those are structured objects, not
  /// scalar property values) plus [tags] under the synthetic key `tags` —
  /// see the `add-databases` design's "Property values live in SQLite"
  /// decision. Called from inside [upsert]/[_upsertNoTx]'s transaction, so
  /// it never opens its own.
  void _upsertPropertyIndex({
    required String id,
    required String title,
    required String path,
    required DateTime createdAt,
    required DateTime updatedAt,
    required Set<String> tags,
    required Map<String, Object?> extra,
    required bool isDefinition,
  }) {
    _upsertNoteMetaStmt.execute([
      id,
      title,
      path,
      createdAt.toUtc().toIso8601String(),
      updatedAt.toUtc().toIso8601String(),
      isDefinition ? 1 : 0,
      jsonEncode(
        extra,
        toEncodable: (o) => o is DateTime ? o.toUtc().toIso8601String() : o,
      ),
    ]);
    _deletePropertiesStmt.execute([id]);
    for (final entry in extra.entries) {
      if (kServerInterpretedKeys.contains(entry.key)) continue;
      _writeProperty(id, entry.key, entry.value);
    }
    if (tags.isNotEmpty) {
      var ordinal = 0;
      for (final tag in tags) {
        _insertPropertyStmt.execute([
          id,
          'tags',
          ordinal,
          tag,
          null,
          null,
          null,
          null,
        ]);
        ordinal++;
      }
    }
  }

  /// Writes one or more `note_properties` rows for [key]/[value]: a `List`
  /// expands to one row per element (with a 0-based `ordinal`); any other
  /// value writes a single row at ordinal 0. `null` (unset) and unsupported
  /// nested `Map` values write nothing — they carry no scalar to index.
  void _writeProperty(String noteId, String key, Object? value) {
    if (value == null) return;
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _writeScalarProperty(noteId, key, i, value[i]);
      }
      return;
    }
    _writeScalarProperty(noteId, key, 0, value);
  }

  void _writeScalarProperty(
    String noteId,
    String key,
    int ordinal,
    Object? value,
  ) {
    if (value == null) return;
    String? text;
    double? numValue;
    int? boolValue;
    String? date;
    String? day;
    if (value is bool) {
      boolValue = value ? 1 : 0;
    } else if (value is num) {
      numValue = value.toDouble();
    } else if (value is DateTime) {
      final utc = value.toUtc();
      text = utc.toIso8601String();
      date = text;
      day = _dayOf(utc);
    } else if (value is String) {
      text = value;
      final parsed = _parseDateShaped(value);
      if (parsed != null) {
        date = parsed.instant;
        day = parsed.day;
      }
    } else {
      // Nested Map or another unsupported shape: not indexed as a scalar,
      // but still visible via `note_meta.frontmatter_json`.
      return;
    }
    _insertPropertyStmt.execute([
      noteId,
      key,
      ordinal,
      text,
      numValue,
      boolValue,
      date,
      day,
    ]);
  }

  /// Day-only frontmatter pattern (`YYYY-MM-DD`), per the "date semantics"
  /// requirement.
  static final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Full ISO 8601 timestamp pattern, deliberately narrower than
  /// [DateTime.tryParse] accepts so an arbitrary text value never gets
  /// mistaken for a date.
  static final RegExp _timestampPattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$',
  );

  /// Normalises a date-shaped [value] — a bare `YYYY-MM-DD` or a full ISO
  /// 8601 timestamp — to a UTC instant plus its calendar day, per the
  /// `databases` spec's "Every `date` value SHALL be normalised to a UTC
  /// instant plus its calendar day" requirement. Returns `null` when
  /// [value] isn't shaped like a date at all, so it's indexed as plain
  /// text only.
  static ({String instant, String day})? _parseDateShaped(String value) {
    if (_dayPattern.hasMatch(value)) {
      return (instant: '${value}T00:00:00.000Z', day: value);
    }
    if (_timestampPattern.hasMatch(value)) {
      final parsed = DateTime.tryParse(value);
      if (parsed == null) return null;
      final utc = parsed.toUtc();
      return (instant: utc.toIso8601String(), day: _dayOf(utc));
    }
    return null;
  }

  static String _dayOf(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';

  /// Removes the row for [id], its outgoing `link_edges` rows, its
  /// `note_meta`/`note_properties` rows, and (when an embedding provider
  /// is configured) its `note_vectors` row. Idempotent: removing a missing
  /// row succeeds silently.
  void delete(String id) {
    _db.execute('BEGIN');
    try {
      _deleteStmt.execute([id]);
      _deleteLinkEdgesStmt.execute([id]);
      _deleteNoteMetaStmt.execute([id]);
      _deletePropertiesStmt.execute([id]);
      if (_embeddingProvider != null) {
        _deleteVectorStmt.execute([id]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Reciprocal Rank Fusion constant, per the add-hybrid-search design's
  /// documented default (unvalidated against real content yet — a
  /// deliberate non-goal of that change, revisit empirically later).
  static const double _fusionK = 60;

  /// Candidate-set size pulled from each ranker before fusion, independent
  /// of the caller's [search] `limit` — fusion needs a wide-enough pool
  /// from both rankers to combine before truncating to what the caller
  /// asked for.
  static const int _fusionCandidateLimit = 50;

  /// Runs an FTS5 [query] and, when an embedding provider is configured,
  /// fuses the result with a vector KNN search via Reciprocal Rank Fusion
  /// — optionally narrowed to notes whose `path` equals or is nested under
  /// [path] and/or whose tag set contains [tag] (case-insensitive,
  /// matching `tags.dart`'s matching rule), applied to both rankers.
  /// Throws [InvalidSearchQueryException] if [query] is not a valid FTS5
  /// expression.
  ///
  /// Without a configured provider (or when it fails to produce a query
  /// embedding), this is exactly the pre-hybrid-search BM25-only behavior.
  /// `async` so the query embedding can be requested before running the
  /// (synchronous) FTS5 query rather than after it — the network round
  /// trip and the local query then overlap instead of adding up serially.
  Future<List<SearchHit>> search(
    String query, {
    int limit = 50,
    String? path,
    String? tag,
  }) async {
    final span = _tracer.startSpan('search.query');
    try {
      final List<SearchHit> hits;
      final provider = _embeddingProvider;
      if (provider == null) {
        hits = _runFtsQueryWithFallback(
          query,
          limit: limit,
          path: path,
          tag: tag,
          span: span,
        );
      } else {
        // Fusion needs at least _fusionCandidateLimit candidates from each
        // ranker to combine before truncating to the caller's limit, but a
        // caller-requested limit larger than that must still be honored —
        // including on the provider-failure fallback path below, which
        // returns BM25 candidates directly rather than a fused set.
        final candidateLimit =
            limit > _fusionCandidateLimit ? limit : _fusionCandidateLimit;
        // Kick off the query embedding request without awaiting it yet,
        // so it's in flight while the synchronous BM25 query below runs.
        final embeddingFuture = embedOrNull(provider, query, logger: _log);
        final bm25Hits = _runFtsQueryWithFallback(
          query,
          limit: candidateLimit,
          path: path,
          tag: tag,
          span: span,
        );
        final queryEmbedding = await embeddingFuture;
        if (queryEmbedding == null) {
          hits = bm25Hits.take(limit).toList();
        } else {
          final vectorHits = vectorSearch(queryEmbedding, k: candidateLimit);
          hits = _fuse(
            bm25Hits: bm25Hits,
            vectorHits: vectorHits,
            limit: limit,
            path: path,
            tag: tag,
          );
        }
      }
      span.setAttribute('search.hit_count', hits.length);
      return hits;
    } on SqliteException catch (e, st) {
      _log.warning('Invalid search query "$query": ${e.message}');
      final exception = InvalidSearchQueryException(
        original: query,
        reason: e.message,
      );
      span
        ..recordException(exception, stackTrace: st)
        ..setStatus(StatusCode.error, description: exception.toString());
      throw exception;
    } catch (e, st) {
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(StatusCode.error, description: e.toString());
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Runs [_runFtsQuery], retrying once with punctuation neutralized (see
  /// [_sanitizeFtsQuery]) if the raw query fails to parse as FTS5 syntax —
  /// shared by both [search]'s no-provider path and hybrid fusion's BM25
  /// candidate gathering. Sets `search.query_sanitized` on [span] when the
  /// fallback succeeds. Rethrows the *original* [SqliteException] if the
  /// sanitized retry also fails to parse, so [search]'s error message
  /// describes the query the caller actually typed, not the fallback.
  List<SearchHit> _runFtsQueryWithFallback(
    String query, {
    required int limit,
    required Span span,
    String? path,
    String? tag,
  }) {
    try {
      return _runFtsQuery(query, limit: limit, path: path, tag: tag);
    } on SqliteException catch (original) {
      final sanitized = _sanitizeFtsQuery(query);
      if (sanitized == query) rethrow;
      try {
        final hits =
            _runFtsQuery(sanitized, limit: limit, path: path, tag: tag);
        span.setAttribute('search.query_sanitized', true);
        return hits;
      } on SqliteException {
        // Sanitizing didn't help; report the original query's error.
        throw original;
      }
    }
  }

  /// Runs [ftsQuery] as an FTS5 `MATCH` expression, applying the same
  /// [path]/[tag]/[limit] narrowing as [search]. Throws [SqliteException]
  /// unchanged on a syntax error, so [_runFtsQueryWithFallback] can retry
  /// with a different query string.
  List<SearchHit> _runFtsQuery(
    String ftsQuery, {
    required int limit,
    String? path,
    String? tag,
  }) {
    final conditions = ['notes_fts MATCH ?'];
    final params = <Object?>[ftsQuery];
    if (path != null) {
      // Avoided LIKE here: a folder name containing `%` or `_` would
      // otherwise be misinterpreted as a wildcard.
      conditions.add(
        "(path = ? OR substr(path, 1, length(?) + 1) = ? || '/')",
      );
      params.addAll([path, path, path]);
    }
    if (tag != null) {
      conditions.add("instr(tags, ' ' || ? || ' ') > 0");
      params.add(tag.toLowerCase());
    }
    params.add(limit);
    final rows = _db.select(
      'SELECT id, title, path, updated_at, '
      "snippet(notes_fts, 3, '<mark>', '</mark>', '…', 16) AS snippet, "
      'bm25(notes_fts) AS rank '
      'FROM notes_fts '
      'WHERE ${conditions.join(' AND ')} '
      'ORDER BY rank '
      'LIMIT ?;',
      params,
    );
    return [
      for (final row in rows)
        SearchHit(
          id: row['id'] as String,
          title: row['title'] as String,
          path: row['path'] as String,
          snippet: row['snippet'] as String,
          rank: (row['rank'] as num).toDouble(),
          updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
        ),
    ];
  }

  /// Combines [bm25Hits] and [vectorHits] via Reciprocal Rank Fusion:
  /// `score(id) = Σ 1/(k + rankInList)` over whichever of the two ranked
  /// lists contain `id`, 1-based rank position within each list. A note
  /// present in only one list still gets a (weaker) score rather than
  /// being dropped.
  ///
  /// [bm25Hits] already carry full [SearchHit] data (including an FTS5
  /// snippet) since they came from a `MATCH` query. A note that
  /// [vectorHits] names but [bm25Hits] doesn't has no FTS snippet context,
  /// so its [SearchHit] is built from a raw lookup with a plain-text
  /// excerpt — and, since [vectorSearch] doesn't apply [path]/[tag]
  /// filtering the way the BM25 query does, that filter is re-applied
  /// here for vector-only notes.
  List<SearchHit> _fuse({
    required List<SearchHit> bm25Hits,
    required List<VectorHit> vectorHits,
    required int limit,
    String? path,
    String? tag,
  }) {
    final bm25RankById = <String, int>{
      for (var i = 0; i < bm25Hits.length; i++) bm25Hits[i].id: i + 1,
    };
    final vectorRankById = <String, int>{
      for (var i = 0; i < vectorHits.length; i++) vectorHits[i].id: i + 1,
    };
    final bm25HitById = {for (final h in bm25Hits) h.id: h};

    // One batched lookup for every vector-only id, instead of one query
    // per id inside the loop below.
    final vectorOnlyIds =
        vectorRankById.keys.where((id) => !bm25HitById.containsKey(id));
    final metaById = _lookupNoteMetaBatch(vectorOnlyIds);

    final hits = <SearchHit>[];
    for (final id in {...bm25RankById.keys, ...vectorRankById.keys}) {
      final bm25Rank = bm25RankById[id];
      final vectorRank = vectorRankById[id];
      final score = (bm25Rank != null ? 1 / (_fusionK + bm25Rank) : 0.0) +
          (vectorRank != null ? 1 / (_fusionK + vectorRank) : 0.0);

      final existing = bm25HitById[id];
      if (existing != null) {
        hits.add(existing.copyWith(rank: -score));
        continue;
      }

      final meta = metaById[id];
      if (meta == null) continue;
      if (path != null && !_pathMatches(meta.path, path)) continue;
      if (tag != null && !_tagsContain(meta.tags, tag)) continue;
      hits.add(
        SearchHit(
          id: id,
          title: meta.title,
          path: meta.path,
          snippet: computeExcerpt(meta.content),
          updatedAt: meta.updatedAt,
          rank: -score,
        ),
      );
    }

    hits.sort((a, b) => a.rank.compareTo(b.rank));
    return hits.take(limit).toList();
  }

  /// Raw note metadata for every id in [ids], read directly from
  /// `notes_fts` (its `id`/`path`/`tags` columns are `UNINDEXED` — a plain
  /// `IN (...)` lookup, not `MATCH`) in one query rather than one per id.
  /// An id with no matching row (e.g. deleted between when its embedding
  /// was written and now) is simply absent from the result.
  Map<String, _NoteMeta> _lookupNoteMetaBatch(Iterable<String> ids) {
    final idList = ids.toList();
    if (idList.isEmpty) return const {};
    final placeholders = List.filled(idList.length, '?').join(',');
    final rows = _db.select(
      'SELECT id, title, path, content, updated_at, tags '
      'FROM notes_fts WHERE id IN ($placeholders);',
      idList,
    );
    return {
      for (final row in rows)
        row['id'] as String: _NoteMeta(
          title: row['title'] as String,
          path: row['path'] as String,
          content: row['content'] as String,
          updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
          tags: row['tags'] as String,
        ),
    };
  }

  /// Whether [notePath] equals or is nested under [filterPath] — mirrors
  /// [_runFtsQuery]'s SQL path condition for use against a single
  /// in-memory row instead of a WHERE clause.
  static bool _pathMatches(String notePath, String filterPath) =>
      notePath == filterPath || notePath.startsWith('$filterPath/');

  /// Whether [encodedTags] (as produced by [_encodeTags]) contains [tag]
  /// — mirrors [_runFtsQuery]'s SQL tag condition.
  static bool _tagsContain(String encodedTags, String tag) =>
      encodedTags.contains(' ${tag.toLowerCase()} ');

  /// Runs a K-nearest-neighbors query against `note_vectors`, returning up
  /// to [k] hits ordered by ascending distance (most similar first).
  /// Returns an empty list when no embedding provider is configured (the
  /// table doesn't exist) or when `note_vectors` has no rows — neither is
  /// an error condition, per the "search remains available" requirement.
  @visibleForTesting
  List<VectorHit> vectorSearch(
    List<double> queryEmbedding, {
    int k = _fusionCandidateLimit,
  }) {
    if (_embeddingProvider == null) return const [];
    final rows = _db.select(
      'SELECT e.id, v.distance FROM note_vectors AS e '
      "JOIN vector_full_scan('note_vectors', 'embedding', "
      'vector_as_f32(?), ?) AS v '
      'ON e.rowid = v.rowid '
      'ORDER BY v.distance;',
      [_encodeVector(queryEmbedding), k],
    );
    return [
      for (final row in rows)
        VectorHit(
          id: row['id'] as String,
          distance: (row['distance'] as num).toDouble(),
        ),
    ];
  }

  /// Default number of notes embedded per batch during [backfillEmbeddings].
  static const int _defaultBackfillBatchSize = 10;

  /// Default pause between [backfillEmbeddings] batches, giving a local
  /// embedding server (e.g. Ollama) room to breathe rather than firing
  /// every request at once.
  static const Duration _defaultBackfillDelay = Duration(milliseconds: 200);

  /// Computes and stores embeddings for every note present in `notes_fts`
  /// but missing from `note_vectors` — notes written before an embedding
  /// provider was configured, or left behind by a prior failed/partial
  /// backfill. Does nothing when no provider is configured.
  ///
  /// Processes ids in batches of [batchSize], pausing [delayBetweenBatches]
  /// between (not within) batches via [sleep] — overridable in tests to
  /// avoid real delays; defaults to [Future.delayed]. Within a batch,
  /// `embed()` calls run concurrently (independent requests to the same
  /// provider); the delay between batches is what limits overall request
  /// rate, not serializing within one. A note whose `embed()` call fails
  /// is simply left for the next backfill pass (same best-effort
  /// semantics as the write path); all of a batch's successful embeddings
  /// are written in one transaction.
  Future<void> backfillEmbeddings({
    int batchSize = _defaultBackfillBatchSize,
    Duration delayBetweenBatches = _defaultBackfillDelay,
    Future<void> Function(Duration)? sleep,
  }) async {
    final provider = _embeddingProvider;
    if (provider == null) return;
    final sleepFn = sleep ?? Future<void>.delayed;

    final pending = _idsMissingEmbeddings();
    for (var offset = 0; offset < pending.length; offset += batchSize) {
      final batch = pending.skip(offset).take(batchSize);
      final embeddings = await Future.wait([
        for (final note in batch)
          embedOrNull(
            provider,
            embeddingInputFor(title: note.title, content: note.content),
            logger: _log,
          ).then((embedding) => (id: note.id, embedding: embedding)),
      ]);

      _db.execute('BEGIN');
      try {
        for (final result in embeddings) {
          if (result.embedding == null) continue;
          _upsertVectorStmt.execute([
            result.id,
            _encodeVector(result.embedding!),
          ]);
        }
        _db.execute('COMMIT');
      } catch (e) {
        _db.execute('ROLLBACK');
        rethrow;
      }

      if (offset + batchSize < pending.length) {
        await sleepFn(delayBetweenBatches);
      }
    }
  }

  /// `(id, title, content)` for every note present in `notes_fts` but
  /// absent from `note_vectors`, in one query — [backfillEmbeddings] needs
  /// all three to compute each note's embedding (see [embeddingInputFor]).
  List<({String id, String title, String content})> _idsMissingEmbeddings() {
    final rows = _db.select(
      'SELECT id, title, content FROM notes_fts '
      'WHERE id NOT IN (SELECT id FROM note_vectors);',
    );
    return [
      for (final row in rows)
        (
          id: row['id'] as String,
          title: row['title'] as String,
          content: row['content'] as String,
        ),
    ];
  }

  /// Neutralizes punctuation that trips FTS5's query-string parser but
  /// carries no FTS5 meaning (e.g. a sentence-ending `?` or an apostrophe
  /// in "isn't"), by replacing it with a space. FTS5 syntax characters
  /// (`"`, `*`, `(`, `)`, `:`) are preserved so deliberate phrase/prefix/
  /// column-filter queries are untouched. [search] only tries this as a
  /// fallback after the raw query fails to parse, so genuine syntax
  /// errors (e.g. an unterminated quote) still surface as
  /// [InvalidSearchQueryException].
  static final RegExp _ftsUnsafeChars = RegExp(
    r'[^\p{L}\p{N}\s"*():]',
    unicode: true,
  );

  static String _sanitizeFtsQuery(String query) =>
      _ftsUnsafeChars.hasMatch(query)
          ? query.replaceAll(_ftsUnsafeChars, ' ').trim()
          : query;

  /// Returns every note flagged `is_definition = 1` in `note_meta` — every
  /// note whose frontmatter carried `type: database` at its last
  /// [upsert], valid or not — so `DatabaseRegistry.rebuild` can reparse
  /// every candidate definition on startup without a separate file scan
  /// (see the `add-databases` design's "Definition notes are parsed into
  /// an in-memory `DatabaseRegistry`, rebuilt on startup from the
  /// `note_meta` table" decision).
  List<DefinitionSourceRow> definitionsSource() {
    final rows = _db.select(
      'SELECT note_id, title, path, created_at, updated_at, '
      'frontmatter_json FROM note_meta WHERE is_definition = 1;',
    );
    return [
      for (final row in rows)
        DefinitionSourceRow(
          id: row['note_id'] as String,
          title: row['title'] as String,
          path: row['path'] as String,
          createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
          updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
          extra: (jsonDecode(row['frontmatter_json'] as String) as Map)
              .cast<String, Object?>(),
        ),
    ];
  }

  /// Closes the database file. After calling this method the index must
  /// not be used again.
  void close() {
    _upsertStmt.close();
    _deleteStmt.close();
    _deleteLinkEdgesStmt.close();
    _insertLinkEdgeStmt.close();
    _upsertNoteMetaStmt.close();
    _deleteNoteMetaStmt.close();
    _deletePropertiesStmt.close();
    _insertPropertyStmt.close();
    // Only touched when a provider is configured — accessing these getters
    // when `note_vectors` doesn't exist would prepare a statement against a
    // missing table and throw.
    if (_embeddingProvider != null) {
      _upsertVectorStmt.close();
      _deleteVectorStmt.close();
    }
    _db.close();
  }

  /// Encodes [tags] as a space-delimited, lowercased, space-padded string
  /// (`" urgent finance "`) so [search]'s `tag` filter can test for exact
  /// membership with `instr(tags, ' ' || ? || ' ')` without a separate
  /// join table — a personal vault's tag cardinality doesn't warrant one.
  static String _encodeTags(Set<String> tags) =>
      ' ${tags.map((t) => t.toLowerCase()).join(' ')} ';

  /// Encodes [vector] as the JSON-array-string literal `sqlite_vector`'s
  /// `vector_as_f32` scalar function expects (confirmed by the task 4.1
  /// spike — it does not accept a bound `List<double>` directly).
  static String _encodeVector(List<double> vector) => '[${vector.join(',')}]';

  Future<int> _rebuild(Storage storage) async {
    var count = 0;
    _db.execute('BEGIN');
    try {
      _db
        ..execute('DELETE FROM notes_fts;')
        ..execute('DELETE FROM link_edges;');
      final summaries = await storage.list();
      // A self-contained title -> id resolution map, mirroring
      // MetaIndex.resolveTitle's "ascending id wins" tie-break, so a
      // full rebuild resolves link edges the same way live writes do
      // without SearchIndex needing to depend on MetaIndex at all.
      final sortedByTitle = [...summaries]
        ..sort((a, b) => a.id.compareTo(b.id));
      final titleToId = <String, String>{};
      for (final s in sortedByTitle) {
        titleToId.putIfAbsent(s.title, () => s.id);
      }
      for (final summary in summaries) {
        final note = await storage.read(summary.id);
        final links = [
          for (final link in parseLinks(note.content))
            SearchLinkEdge(
              targetTitle: link.targetTitle,
              targetId: titleToId[link.targetTitle],
            ),
        ];
        _upsertNoTx(
          id: note.id,
          title: note.title,
          path: note.path,
          content: note.content,
          updatedAt: note.updatedAt,
          tags: summary.tags,
          links: links,
          extra: note.extra,
          createdAt: note.createdAt,
          isDefinition: note.extra['type'] == 'database',
        );
        count++;
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return count;
  }

  static bool _isHealthy(File dbFile, {required Logger log}) {
    Database? db;
    try {
      db = sqlite3.open(dbFile.path);
      final integrity = db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        log.warning('integrity_check failed: ${integrity.toList()}');
        return false;
      }
      // Check schema version. Missing meta table OR mismatched value is
      // treated as "stale".
      final hasMeta = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='meta';",
      );
      if (hasMeta.isEmpty) return false;
      final versionRow = db.select(
        "SELECT value FROM meta WHERE key='schema_version';",
      );
      if (versionRow.isEmpty) return false;
      final version = int.tryParse(versionRow.first.values.first.toString());
      if (version != kSearchSchemaVersion) {
        log.warning(
          'schema_version mismatch (have $version, '
          'want $kSearchSchemaVersion)',
        );
        return false;
      }
      return true;
    } on SqliteException catch (e) {
      log.warning('search.db open failed: $e');
      return false;
    } finally {
      db?.close();
    }
  }

  /// [dimensions] is the configured embedding provider's vector size, or
  /// `null` when no provider is configured — in which case `note_vectors`
  /// is not created at all, matching pre-hybrid-search behavior exactly.
  static void _initSchema(Database db, {int? dimensions}) {
    db
      ..execute('''
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''')
      ..execute(
        'INSERT OR REPLACE INTO meta (key, value) VALUES '
        "('schema_version', '$kSearchSchemaVersion');",
      )
      ..execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          id UNINDEXED,
          title,
          path UNINDEXED,
          content,
          updated_at UNINDEXED,
          tags UNINDEXED,
          tokenize = "porter unicode61"
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS link_edges (
          source_id TEXT NOT NULL,
          target_title TEXT NOT NULL,
          target_id TEXT,
          resolved INTEGER NOT NULL
        );
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS link_edges_source_idx
          ON link_edges(source_id);
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS note_meta (
          note_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          path TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          is_definition INTEGER NOT NULL DEFAULT 0,
          frontmatter_json TEXT NOT NULL DEFAULT '{}'
        );
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_meta_path_idx ON note_meta(path);
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_meta_updated_at_idx
          ON note_meta(updated_at);
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_meta_created_at_idx
          ON note_meta(created_at);
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS note_properties (
          note_id TEXT NOT NULL,
          key TEXT NOT NULL,
          ordinal INTEGER NOT NULL DEFAULT 0,
          text_value TEXT,
          num_value REAL,
          bool_value INTEGER,
          date_value TEXT,
          day_value TEXT
        );
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_properties_note_id_idx
          ON note_properties(note_id);
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_properties_key_text_idx
          ON note_properties(key, text_value);
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_properties_key_num_idx
          ON note_properties(key, num_value);
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS note_properties_key_date_idx
          ON note_properties(key, date_value);
      ''');
    if (dimensions != null) {
      db
        ..execute('''
          CREATE TABLE IF NOT EXISTS note_vectors (
            id TEXT PRIMARY KEY,
            embedding BLOB NOT NULL
          );
        ''')
        ..execute(
          "SELECT vector_init('note_vectors', 'embedding', "
          "'type=FLOAT32,dimension=$dimensions');",
        );
    }
  }
}
