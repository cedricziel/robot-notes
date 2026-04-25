import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/storage.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schema version for the FTS5 search index. Bumping this constant forces a
/// rebuild on the next startup — useful when the index columns or tokenizer
/// configuration change in incompatible ways.
const int kSearchSchemaVersion = 1;

/// Result row returned by [SearchIndex.search].
@immutable
class SearchHit {
  /// Builds a result describing one matching note.
  const SearchHit({
    required this.id,
    required this.title,
    required this.snippet,
    required this.rank,
  });

  /// Note id (ULID).
  final String id;

  /// Note title at index time.
  final String title;

  /// Highlighted excerpt of the matched content with `<mark>` markers.
  final String snippet;

  /// FTS5 rank — lower is more relevant. Negative values come from
  /// `bm25()` and are passed through unchanged.
  final double rank;
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
  SearchIndex._(this._db);

  final Database _db;
  late final PreparedStatement _upsertStmt = _db.prepare(
    'INSERT OR REPLACE INTO notes_fts (rowid, id, title, content) '
    'VALUES ((SELECT rowid FROM notes_fts WHERE id = ?1), ?1, ?2, ?3);',
  );
  late final PreparedStatement _deleteStmt = _db.prepare(
    'DELETE FROM notes_fts WHERE id = ?1;',
  );

  /// Opens the index at [dbFile] (creating its parent directory if
  /// necessary). If the file is missing, corrupt, or schema-mismatched the
  /// index is rebuilt by scanning [storage].
  ///
  /// Operators can flip [forceRebuild] to drop the existing file regardless
  /// of state — useful for ops runbooks that want to reseed from disk.
  static Future<SearchIndex> open({
    required File dbFile,
    required Storage storage,
    Logger? logger,
    bool forceRebuild = false,
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

    final db = sqlite3.open(dbFile.path);
    _initSchema(db);

    final index = SearchIndex._(db);
    if (rebuild) {
      final loaded = await index._rebuild(storage);
      log.info('search.db rebuilt with $loaded note(s)');
    }
    return index;
  }

  /// Inserts or replaces a row for [id] with [title] and [content].
  void upsert({
    required String id,
    required String title,
    required String content,
  }) {
    _upsertStmt.execute([id, title, content]);
  }

  /// Removes the row for [id]. Idempotent: removing a missing row succeeds
  /// silently.
  void delete(String id) {
    _deleteStmt.execute([id]);
  }

  /// Runs an FTS5 [query] and returns the matching rows ordered by rank
  /// ascending (most relevant first). Throws [InvalidSearchQueryException]
  /// if the query is not a valid FTS5 expression.
  ///
  /// Snippets contain `<mark>...</mark>` markers around matched terms.
  List<SearchHit> search(String query, {int limit = 50}) {
    try {
      final rows = _db.select(
        'SELECT id, title, '
        "snippet(notes_fts, 2, '<mark>', '</mark>', '…', 16) AS snippet, "
        'bm25(notes_fts) AS rank '
        'FROM notes_fts '
        'WHERE notes_fts MATCH ?1 '
        'ORDER BY rank '
        'LIMIT ?2;',
        [query, limit],
      );
      return [
        for (final row in rows)
          SearchHit(
            id: row['id'] as String,
            title: row['title'] as String,
            snippet: row['snippet'] as String,
            rank: (row['rank'] as num).toDouble(),
          ),
      ];
    } on SqliteException catch (e) {
      throw InvalidSearchQueryException(
        original: query,
        reason: e.message,
      );
    }
  }

  /// Closes the database file. After calling this method the index must
  /// not be used again.
  void close() {
    _upsertStmt.dispose();
    _deleteStmt.dispose();
    _db.dispose();
  }

  Future<int> _rebuild(Storage storage) async {
    var count = 0;
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM notes_fts;');
      for (final summary in await storage.list()) {
        final note = await storage.read(summary.id);
        upsert(id: note.id, title: note.title, content: note.content);
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
      db?.dispose();
    }
  }

  static void _initSchema(Database db) {
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
          content,
          tokenize = "porter unicode61"
        );
      ''');
  }
}
