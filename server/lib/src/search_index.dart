import 'dart:async';
import 'dart:io';

import 'package:flutter_otel_api/flutter_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
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
const int kSearchSchemaVersion = 4;

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

  /// Highlighted excerpt of the matched content with `<mark>` markers.
  final String snippet;

  /// FTS5 rank — lower is more relevant. Negative values come from
  /// `bm25()` and are passed through unchanged.
  final double rank;

  /// The note's `updated_at` as of the last [SearchIndex.upsert].
  final DateTime updatedAt;
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
  static Future<SearchIndex> open({
    required File dbFile,
    required Storage storage,
    Logger? logger,
    Tracer? tracer,
    bool forceRebuild = false,
    EmbeddingProvider? embeddingProvider,
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
  void upsert({
    required String id,
    required String title,
    required String content,
    required DateTime updatedAt,
    String path = '',
    Set<String> tags = const {},
    List<SearchLinkEdge> links = const [],
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
      );
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
  }

  /// Removes the row for [id] and its outgoing `link_edges` rows.
  /// Idempotent: removing a missing row succeeds silently.
  void delete(String id) {
    _db.execute('BEGIN');
    try {
      _deleteStmt.execute([id]);
      _deleteLinkEdgesStmt.execute([id]);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs an FTS5 [query] and returns the matching rows ordered by rank
  /// ascending (most relevant first), optionally narrowed to notes whose
  /// `path` equals or is nested under [path] and/or whose tag set
  /// contains [tag] (case-insensitive, matching `tags.dart`'s matching
  /// rule). Throws [InvalidSearchQueryException] if the query is not a
  /// valid FTS5 expression.
  ///
  /// Snippets contain `<mark>...</mark>` markers around matched terms.
  ///
  /// Wrapped in a `search.query` span (not made [Span.current], since this
  /// method is synchronous and [Tracer.startActiveSpan] requires an async
  /// body — a nested log call still correlates to whichever span was
  /// already ambient, typically the request's own).
  List<SearchHit> search(
    String query, {
    int limit = 50,
    String? path,
    String? tag,
  }) {
    final span = _tracer.startSpan('search.query');
    try {
      final conditions = ['notes_fts MATCH ?'];
      final params = <Object?>[query];
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
      final hits = [
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

  /// Runs a K-nearest-neighbors query against `note_vectors`, returning up
  /// to [k] hits ordered by ascending distance (most similar first).
  /// Returns an empty list when no embedding provider is configured (the
  /// table doesn't exist) or when `note_vectors` has no rows — neither is
  /// an error condition, per the "search remains available" requirement.
  @visibleForTesting
  List<VectorHit> vectorSearch(List<double> queryEmbedding, {int k = 50}) {
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

  /// Closes the database file. After calling this method the index must
  /// not be used again.
  void close() {
    _upsertStmt.close();
    _deleteStmt.close();
    _deleteLinkEdgesStmt.close();
    _insertLinkEdgeStmt.close();
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
