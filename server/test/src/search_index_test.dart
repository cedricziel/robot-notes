import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_otel_sdk/dart_otel_sdk.dart' hide LogRecord, Logger;
import 'package:logging/logging.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'embeddings/fake_embedding_provider.dart';
import 'search_test_helpers.dart';

class _RecordingSpanProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-search-test-');
}

Storage _storage(Directory tmp) =>
    Storage(contentDir: Directory('${tmp.path}/content'));

File _dbFile(Directory tmp) => File('${tmp.path}/search.db');

/// Reads every `link_edges` row for [sourceId] directly, bypassing the
/// [SearchIndex] API — there is no public accessor for this derived table
/// since only [SearchIndex] itself and its rebuild path need to read it;
/// tests open a second connection to the same file, mirroring how this
/// file already tampers with `meta` directly for schema-mismatch tests.
List<Row> _linkEdges(Directory tmp, String sourceId) {
  final db = sqlite3.open(_dbFile(tmp).path);
  try {
    return db.select('SELECT * FROM link_edges WHERE source_id = ?;', [
      sourceId,
    ]);
  } finally {
    db.close();
  }
}

/// Arbitrary fixed instant for tests that don't care about the actual
/// value of `updatedAt`, only that one was supplied.
final _testStamp = DateTime.utc(2026);

/// Reads a `note_meta` row directly, bypassing [SearchIndex]'s public API
/// — mirrors [_linkEdges]'s approach of opening a second connection to
/// inspect a derived table.
Map<String, Object?> _noteMeta(Directory tmp, String noteId) {
  final row = _noteMetaOrNull(tmp, noteId);
  if (row == null) {
    throw StateError('no note_meta row for $noteId');
  }
  return row;
}

Map<String, Object?>? _noteMetaOrNull(Directory tmp, String noteId) {
  final db = sqlite3.open(_dbFile(tmp).path);
  try {
    final rows = db.select(
      'SELECT * FROM note_meta WHERE note_id = ?;',
      [noteId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  } finally {
    db.close();
  }
}

/// Reads every `note_properties` row for [noteId]/[key] directly.
List<Row> _noteProperties(Directory tmp, String noteId, String key) {
  final db = sqlite3.open(_dbFile(tmp).path);
  try {
    return db.select(
      'SELECT * FROM note_properties WHERE note_id = ? AND key = ?;',
      [noteId, key],
    );
  } finally {
    db.close();
  }
}

Future<SearchIndex> _open(
  Directory tmp, {
  Storage? storage,
  Logger? logger,
  Tracer? tracer,
  bool forceRebuild = false,
  EmbeddingProvider? embeddingProvider,
  bool autoBackfill = true,
}) {
  return SearchIndex.open(
    dbFile: _dbFile(tmp),
    storage: storage ?? _storage(tmp),
    logger: logger,
    tracer: tracer,
    forceRebuild: forceRebuild,
    embeddingProvider: embeddingProvider,
    autoBackfill: autoBackfill,
  );
}

/// Whether `note_vectors` exists in the `search.db` at [tmp], checked via a
/// second raw connection, mirroring how [_linkEdges] bypasses the public
/// API to inspect derived-table state directly.
bool _hasVectorTable(Directory tmp) {
  final db = sqlite3.open(_dbFile(tmp).path);
  try {
    final rows = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='note_vectors';",
    );
    return rows.isNotEmpty;
  } finally {
    db.close();
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('SearchIndex.open', () {
    test('rebuilds the index when search.db is missing', () async {
      final storage = _storage(tmp);
      final note = await storage.create(
        title: 'Release notes',
        content: 'Shipped the new architecture.',
      );

      expect(_dbFile(tmp).existsSync(), isFalse);
      final index = await _open(tmp, storage: storage);
      addTearDown(index.close);

      expect(_dbFile(tmp).existsSync(), isTrue);
      final hits = await index.search('architecture');
      expect(hits, hasLength(1));
      expect(hits.single.id, note.id);
    });

    test('rebuilds the index when search.db is corrupt', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'Doc', content: 'Hello world');

      // Pre-populate a junk file at the search.db path so PRAGMA
      // integrity_check fails.
      _dbFile(tmp).writeAsBytesSync(List<int>.filled(64, 0xff));

      final logger = Logger.detached('search-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen(
        (rec) => logged.add('${rec.level}:${rec.message}'),
      );

      final index = await _open(tmp, storage: storage, logger: logger);
      addTearDown(index.close);

      expect(
        logged.any((l) => l.contains('unhealthy') || l.contains('open failed')),
        isTrue,
        reason: 'expected a warning about the corrupt db',
      );
      expect(await index.search('hello'), hasLength(1));
    });

    test('reuses a healthy search.db without rebuilding', () async {
      final storage = _storage(tmp);
      final note = await storage.create(title: 'Cached', content: 'durable');

      var index = await _open(tmp, storage: storage);
      index.close();

      // Drop the storage file so a rebuild would produce zero rows. If
      // the existing db is reused the row stays searchable.
      File('${tmp.path}/content/Cached.md').deleteSync();

      index = await _open(tmp, storage: storage);
      addTearDown(index.close);

      final hits = await index.search('durable');
      expect(hits, hasLength(1));
      expect(hits.single.id, note.id);
    });

    test('rebuilds when the schema_version row is missing or stale', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'Bumped', content: 'tokenized words');

      final initial = await _open(tmp, storage: storage);
      initial.close();

      // Simulate a stale-schema db: directly tamper with meta.
      sqlite3.open(_dbFile(tmp).path)
        ..execute("UPDATE meta SET value = '0' WHERE key = 'schema_version';")
        ..close();

      final logger = Logger.detached('search-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen((rec) => logged.add(rec.message));

      final index = await _open(tmp, storage: storage, logger: logger);
      addTearDown(index.close);

      expect(logged.any((l) => l.contains('schema_version mismatch')), isTrue);
      // Surviving content remains searchable after rebuild.
      expect(await index.search('tokenized'), hasLength(1));
    });

    test('rebuilds a pre-hybrid-search v3 search.db (no note_vectors table)',
        () async {
      final storage = _storage(tmp);
      await storage.create(title: 'Bumped', content: 'tokenized words');

      final initial = await _open(tmp, storage: storage);
      initial.close();

      // Simulate the exact prior on-disk shape: schema_version 3, the
      // version this constant held before hybrid search added
      // note_vectors.
      sqlite3.open(_dbFile(tmp).path)
        ..execute("UPDATE meta SET value = '3' WHERE key = 'schema_version';")
        ..close();

      final logger = Logger.detached('search-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen((rec) => logged.add(rec.message));

      final index = await _open(tmp, storage: storage, logger: logger);
      addTearDown(index.close);

      expect(logged.any((l) => l.contains('schema_version mismatch')), isTrue);
      expect(await index.search('tokenized'), hasLength(1));
    });

    test(
      'a schema-4 db is rebuilt on open and the new tables and indexes '
      'exist',
      () async {
        final storage = _storage(tmp);
        await storage.create(title: 'Legacy', content: 'kept searchable');

        final initial = await _open(tmp, storage: storage);
        initial.close();

        // Simulate a pre-databases search.db: schema_version 4, the
        // version this constant held before note_meta/note_properties.
        sqlite3.open(_dbFile(tmp).path)
          ..execute("UPDATE meta SET value = '4' WHERE key = 'schema_version';")
          ..close();

        final index = await _open(tmp, storage: storage);
        addTearDown(index.close);

        final db = sqlite3.open(_dbFile(tmp).path);
        addTearDown(db.close);
        final tables = db
            .select(
              "SELECT name FROM sqlite_master WHERE type='table';",
            )
            .map((r) => r['name'] as String)
            .toSet();
        expect(tables, containsAll(['note_meta', 'note_properties']));
        final indexes = db
            .select(
              "SELECT name FROM sqlite_master WHERE type='index';",
            )
            .map((r) => r['name'] as String)
            .toSet();
        expect(
          indexes,
          containsAll([
            'note_meta_path_idx',
            'note_meta_updated_at_idx',
            'note_meta_created_at_idx',
            'note_properties_key_text_idx',
            'note_properties_key_num_idx',
            'note_properties_key_date_idx',
            'note_properties_note_id_key_idx',
          ]),
        );
      },
    );

    test('rebuild logs the count of indexed notes', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'a', content: 'apple');
      await storage.create(title: 'b', content: 'banana');
      await storage.create(title: 'c', content: 'cherry');

      final logger = Logger.detached('search-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen((rec) => logged.add(rec.message));

      final index = await _open(tmp, storage: storage, logger: logger);
      addTearDown(index.close);

      expect(logged.any((l) => l.contains('rebuilt with 3 note(s)')), isTrue);
    });

    test('rebuild repopulates path, tags, and resolved link edges', () async {
      final storage = _storage(tmp);
      await storage.create(
        title: 'Alpha',
        content: 'Tagged #urgent',
        path: 'Projects',
      );
      await storage.create(
        title: 'Beta',
        content: 'refers to [[Alpha]] and [[Nowhere]]',
      );

      final index = await _open(tmp, storage: storage);
      addTearDown(index.close);

      expect(await index.search('Tagged', path: 'Projects'), hasLength(1));
      expect(await index.search('Tagged', path: 'Elsewhere'), isEmpty);
      expect(await index.search('Tagged', tag: 'urgent'), hasLength(1));
      expect(await index.search('Tagged', tag: 'later'), isEmpty);

      final betaId =
          (await storage.list()).firstWhere((s) => s.title == 'Beta').id;
      final rows = _linkEdges(tmp, betaId);
      final byTitle = {for (final r in rows) r['target_title'] as String: r};
      expect(byTitle['Alpha']!['resolved'], 1);
      expect(byTitle['Alpha']!['target_id'], isNotNull);
      expect(byTitle['Nowhere']!['resolved'], 0);
      expect(byTitle['Nowhere']!['target_id'], isNull);
    });

    test(
      'an old-shape search.db (missing path/tags/link-edges) is rebuilt',
      () async {
        final storage = _storage(tmp);
        await storage.create(title: 'Legacy', content: 'kept searchable');

        // Hand-build a pre-change-shaped search.db: schema_version 2, no
        // path/tags columns on notes_fts, and no link_edges table at all.
        sqlite3.open(_dbFile(tmp).path)
          ..execute('''
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          ''')
          ..execute(
            "INSERT INTO meta (key, value) VALUES ('schema_version', '2');",
          )
          ..execute('''
            CREATE VIRTUAL TABLE notes_fts USING fts5(
              id UNINDEXED,
              title,
              content,
              updated_at UNINDEXED,
              tokenize = "porter unicode61"
            );
          ''')
          ..close();

        final logger = Logger.detached('search-test')..level = Level.ALL;
        final logged = <String>[];
        logger.onRecord.listen((rec) => logged.add(rec.message));

        final index = await _open(tmp, storage: storage, logger: logger);
        addTearDown(index.close);

        expect(
          logged.any((l) => l.contains('mismatch') || l.contains('unhealthy')),
          isTrue,
        );
        expect(await index.search('kept'), hasLength(1));
      },
    );
  });

  group('SearchIndex vector storage', () {
    test(
        'creates note_vectors sized to the provider dimensions when '
        'configured', () async {
      final index = await _open(
        tmp,
        embeddingProvider: FakeEmbeddingProvider(),
      );
      addTearDown(index.close);

      expect(_hasVectorTable(tmp), isTrue);
    });

    test('does not create note_vectors when no provider is configured',
        () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      expect(_hasVectorTable(tmp), isFalse);
    });

    group('vectorSearch', () {
      /// Inserts a raw `note_vectors` row via a second connection — bypasses
      /// `upsert()` (which doesn't write embeddings until a later task) so
      /// this KNN query can be tested against the vector table in
      /// isolation.
      void insertVector(String id, List<double> embedding) {
        final db = sqlite3.open(_dbFile(tmp).path);
        try {
          db.execute(
            'INSERT INTO note_vectors (id, embedding) '
            'VALUES (?, vector_as_f32(?));',
            [id, '[${embedding.join(',')}]'],
          );
        } finally {
          db.close();
        }
      }

      test('returns up to k note ids ordered by ascending distance', () async {
        final index = await _open(
          tmp,
          embeddingProvider: FakeEmbeddingProvider(),
        );
        addTearDown(index.close);

        insertVector('near', [1.0, 2.0, 3.0, 4.0]);
        insertVector('far', [100.0, 200.0, 300.0, 400.0]);
        insertVector('medium', [2.0, 3.0, 4.0, 5.0]);

        final hits = index.vectorSearch([1.0, 2.0, 3.0, 4.0], k: 2);

        expect(hits, hasLength(2));
        expect(hits.map((h) => h.id).toList(), ['near', 'medium']);
        expect(hits[0].distance, lessThan(hits[1].distance));
      });

      test('k larger than the row count returns all available rows', () async {
        final index = await _open(
          tmp,
          embeddingProvider: FakeEmbeddingProvider(),
        );
        addTearDown(index.close);

        insertVector('only', [1.0, 2.0, 3.0, 4.0]);

        final hits = index.vectorSearch([1.0, 2.0, 3.0, 4.0]);

        expect(hits, hasLength(1));
      });

      test('empty note_vectors returns no results, not an error', () async {
        final index = await _open(
          tmp,
          embeddingProvider: FakeEmbeddingProvider(),
        );
        addTearDown(index.close);

        final hits = index.vectorSearch([1.0, 2.0, 3.0, 4.0], k: 5);

        expect(hits, isEmpty);
      });
    });
  });

  group('SearchIndex.upsert / delete', () {
    test('upsert makes a row searchable; replaces on second call', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Original',
        content: 'kangaroo jumps',
        updatedAt: _testStamp,
      );
      expect(await index.search('kangaroo'), hasLength(1));

      index.upsert(
        id: 'n1',
        title: 'Updated',
        content: 'wallaby hops',
        updatedAt: _testStamp,
      );
      expect(await index.search('kangaroo'), isEmpty);
      final hits = await index.search('wallaby');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'Updated');
    });

    test('delete removes a row idempotently', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Doomed',
        content: 'transient',
        updatedAt: _testStamp,
      );
      expect(await index.search('transient'), hasLength(1));

      index
        ..delete('n1')
        ..delete('n1');
      expect(await index.search('transient'), isEmpty);
    });

    test('upsert records path and a queryable tag set', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Budget doc',
        content: 'budget plan',
        updatedAt: _testStamp,
        path: 'Projects/Alpha',
        tags: {'Urgent'},
      );

      expect(
        await index.search('budget', path: 'Projects/Alpha'),
        hasLength(1),
      );
      // 'Projects' is an ancestor folder, so it matches too (nested).
      expect(await index.search('budget', path: 'Projects'), hasLength(1));
      expect(await index.search('budget', path: 'Other'), isEmpty);
      // Case-insensitive, matching tags.dart's own matching rule.
      expect(await index.search('budget', tag: 'urgent'), hasLength(1));
      expect(await index.search('budget', tag: 'URGENT'), hasLength(1));
      expect(await index.search('budget', tag: 'later'), isEmpty);
    });

    test(
      'upsert populates outgoing link edges with resolution state',
      () async {
        final index = await _open(tmp);
        addTearDown(index.close);

        index.upsert(
          id: 'a',
          title: 'A',
          content: 'irrelevant',
          updatedAt: _testStamp,
          links: const [
            SearchLinkEdge(targetTitle: 'B', targetId: 'b'),
            SearchLinkEdge(targetTitle: 'Phantom'),
          ],
        );

        final rows = _linkEdges(tmp, 'a');
        expect(rows, hasLength(2));
        final byTitle = {for (final r in rows) r['target_title'] as String: r};
        expect(byTitle['B']!['target_id'], 'b');
        expect(byTitle['B']!['resolved'], 1);
        expect(byTitle['Phantom']!['target_id'], isNull);
        expect(byTitle['Phantom']!['resolved'], 0);
      },
    );

    test('re-upserting a note replaces its outgoing link edges', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'a',
          title: 'A',
          content: '',
          updatedAt: _testStamp,
          links: const [SearchLinkEdge(targetTitle: 'Old')],
        )
        ..upsert(
          id: 'a',
          title: 'A',
          content: '',
          updatedAt: _testStamp,
          links: const [SearchLinkEdge(targetTitle: 'New')],
        );

      final rows = _linkEdges(tmp, 'a');
      expect(rows.map((r) => r['target_title']), ['New']);
    });

    test("delete removes a note's outgoing link edges too", () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'a',
          title: 'A',
          content: '',
          updatedAt: _testStamp,
          links: const [SearchLinkEdge(targetTitle: 'X')],
        )
        ..delete('a');

      expect(_linkEdges(tmp, 'a'), isEmpty);
    });

    test(
        'stores the embedding when one is supplied and a provider is '
        'configured', () async {
      final index = await _open(
        tmp,
        embeddingProvider: FakeEmbeddingProvider(),
      );
      addTearDown(index.close);

      index.upsert(
        id: 'a',
        title: 'A',
        content: 'hello',
        updatedAt: _testStamp,
        embedding: [1.0, 2.0, 3.0, 4.0],
      );

      expect(vectorRowExists(_dbFile(tmp).path, 'a'), isTrue);
    });

    test(
        'commits the FTS write even when embedding is omitted (no '
        'provider, or the caller could not produce one)', () async {
      final index = await _open(
        tmp,
        embeddingProvider: FakeEmbeddingProvider(),
      );
      addTearDown(index.close);

      index.upsert(
        id: 'a',
        title: 'A',
        content: 'hello',
        updatedAt: _testStamp,
      );

      expect(await index.search('hello'), hasLength(1));
      expect(vectorRowExists(_dbFile(tmp).path, 'a'), isFalse);
    });

    test(
      'upsert writes note_meta with created_at/updated_at/is_definition '
      'and frontmatter_json',
      () async {
        final index = await _open(tmp);
        addTearDown(index.close);

        index.upsert(
          id: 'n1',
          title: 'Projects',
          content: 'a database of projects',
          updatedAt: DateTime.utc(2026, 2),
          createdAt: DateTime.utc(2026, 1),
          isDefinition: true,
          extra: const {
            'type': 'database',
            'source': {'folder': 'Projects'},
          },
        );

        final row = _noteMeta(tmp, 'n1');
        expect(row['created_at'], '2026-01-01T00:00:00.000Z');
        expect(row['updated_at'], '2026-02-01T00:00:00.000Z');
        expect(row['is_definition'], 1);
        final decoded = jsonDecode(row['frontmatter_json'] as String) as Map;
        expect(decoded['type'], 'database');
        expect(decoded['source'], {'folder': 'Projects'});
      },
    );

    test('createdAt defaults to updatedAt and isDefinition defaults false',
        () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Plain',
        content: 'plain note',
        updatedAt: _testStamp,
      );

      final row = _noteMeta(tmp, 'n1');
      expect(row['created_at'], _testStamp.toIso8601String());
      expect(row['is_definition'], 0);
      expect(
          jsonDecode(row['frontmatter_json'] as String), <String, Object?>{});
    });

    test('upsert writes a text property row for a string value', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        extra: const {'status': 'Active'},
      );

      final rows = _noteProperties(tmp, 'n1', 'status');
      expect(rows, hasLength(1));
      expect(rows.single['text_value'], 'Active');
      expect(rows.single['num_value'], isNull);
    });

    test('upsert writes a number property to num_value', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        extra: const {'budget': 42},
      );

      final rows = _noteProperties(tmp, 'n1', 'budget');
      expect(rows.single['num_value'], 42.0);
    });

    test('upsert writes a checkbox property to bool_value', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        extra: const {'done': true},
      );

      final rows = _noteProperties(tmp, 'n1', 'done');
      expect(rows.single['bool_value'], 1);
    });

    test(
      'upsert normalises a day-only date string to date_value/day_value',
      () async {
        final index = await _open(tmp);
        addTearDown(index.close);

        index.upsert(
          id: 'n1',
          title: 'Row',
          content: '',
          updatedAt: _testStamp,
          extra: const {'due': '2026-10-01'},
        );

        final rows = _noteProperties(tmp, 'n1', 'due');
        expect(rows.single['text_value'], '2026-10-01');
        expect(rows.single['day_value'], '2026-10-01');
        expect(rows.single['date_value'], '2026-10-01T00:00:00.000Z');
      },
    );

    test(
      'upsert normalises a full ISO timestamp to date_value/day_value',
      () async {
        final index = await _open(tmp);
        addTearDown(index.close);

        index.upsert(
          id: 'n1',
          title: 'Row',
          content: '',
          updatedAt: _testStamp,
          extra: const {'due': '2026-10-01T09:00:00Z'},
        );

        final rows = _noteProperties(tmp, 'n1', 'due');
        expect(rows.single['day_value'], '2026-10-01');
        expect(rows.single['date_value'], '2026-10-01T09:00:00.000Z');
      },
    );

    test('upsert accepts a YAML DateTime object for a date property', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        extra: {'due': DateTime.utc(2026, 10, 1, 9)},
      );

      final rows = _noteProperties(tmp, 'n1', 'due');
      expect(rows.single['day_value'], '2026-10-01');
      expect(rows.single['date_value'], '2026-10-01T09:00:00.000Z');
    });

    test('upsert expands a list-valued property with ordinals', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        extra: const {
          'labels': ['[[A]]', '[[B]]'],
        },
      );

      final rows = _noteProperties(tmp, 'n1', 'labels').toList()
        ..sort((a, b) => (a['ordinal'] as int).compareTo(b['ordinal'] as int));
      expect(rows.map((r) => r['text_value']), ['[[A]]', '[[B]]']);
      expect(rows.map((r) => r['ordinal']), [0, 1]);
    });

    test('upsert writes computed tags under the synthetic key "tags"',
        () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Row',
        content: '',
        updatedAt: _testStamp,
        tags: {'urgent', 'work'},
      );

      final rows = _noteProperties(tmp, 'n1', 'tags');
      expect(
        rows.map((r) => r['text_value']).toSet(),
        {'urgent', 'work'},
      );
    });

    test('upsert excludes server-interpreted keys from note_properties',
        () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(
        id: 'n1',
        title: 'Projects',
        content: '',
        updatedAt: _testStamp,
        isDefinition: true,
        extra: const {
          'type': 'database',
          'source': {'folder': 'Projects'},
          'properties': {
            'status': {'type': 'select'},
          },
          'views': [
            {'name': 'All', 'type': 'table'},
          ],
        },
      );

      expect(_noteProperties(tmp, 'n1', 'type'), isEmpty);
      expect(_noteProperties(tmp, 'n1', 'source'), isEmpty);
      expect(_noteProperties(tmp, 'n1', 'properties'), isEmpty);
      expect(_noteProperties(tmp, 'n1', 'views'), isEmpty);
    });

    test('upsert replaces note_properties rows on a second call', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'n1',
          title: 'Row',
          content: '',
          updatedAt: _testStamp,
          extra: const {'status': 'Idea'},
        )
        ..upsert(
          id: 'n1',
          title: 'Row',
          content: '',
          updatedAt: _testStamp,
          extra: const {'status': 'Active'},
        );

      final rows = _noteProperties(tmp, 'n1', 'status');
      expect(rows, hasLength(1));
      expect(rows.single['text_value'], 'Active');
    });

    test('delete removes note_meta and note_properties rows', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'n1',
          title: 'Row',
          content: '',
          updatedAt: _testStamp,
          extra: const {'status': 'Idea'},
        )
        ..delete('n1');

      expect(_noteMetaOrNull(tmp, 'n1'), isNull);
      expect(_noteProperties(tmp, 'n1', 'status'), isEmpty);
    });

    test('definitionsSource returns every is_definition row', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'def1',
          title: 'Projects',
          content: '',
          updatedAt: DateTime.utc(2026, 2),
          createdAt: DateTime.utc(2026, 1),
          isDefinition: true,
          extra: const {
            'type': 'database',
            'source': {'folder': 'Projects'},
          },
        )
        ..upsert(
          id: 'row1',
          title: 'Rewrite',
          content: '',
          updatedAt: _testStamp,
          extra: const {'status': 'Idea'},
        );

      final defs = index.definitionsSource();
      expect(defs, hasLength(1));
      final def = defs.single;
      expect(def.id, 'def1');
      expect(def.title, 'Projects');
      expect(def.extra['type'], 'database');
      expect(def.extra['source'], {'folder': 'Projects'});
    });

    test('delete removes the embedding row alongside FTS and link edges',
        () async {
      final index = await _open(
        tmp,
        embeddingProvider: FakeEmbeddingProvider(),
      );
      addTearDown(index.close);

      index
        ..upsert(
          id: 'a',
          title: 'A',
          content: 'hello',
          updatedAt: _testStamp,
          embedding: [1.0, 2.0, 3.0, 4.0],
        )
        ..delete('a');

      expect(vectorRowExists(_dbFile(tmp).path, 'a'), isFalse);
    });
  });

  group('SearchIndex.search', () {
    Future<SearchIndex> seed(Map<String, (String, String)> notes) async {
      final index = await _open(tmp);
      notes.forEach((id, tc) {
        index.upsert(
          id: id,
          title: tc.$1,
          content: tc.$2,
          updatedAt: _testStamp,
        );
      });
      addTearDown(index.close);
      return index;
    }

    test('stems words (run matches running)', () async {
      final index = await seed({
        'n1': ('Race day', 'I went running yesterday.'),
      });
      expect(await index.search('run'), hasLength(1));
      expect(await index.search('runs'), hasLength(1));
      expect(await index.search('running'), hasLength(1));
    });

    test('matches case-insensitively', () async {
      final index = await seed({'n1': ('Hello', 'The quick brown FOX jumps.')});
      expect(await index.search('fox'), hasLength(1));
      expect(await index.search('FOX'), hasLength(1));
      expect(await index.search('Fox'), hasLength(1));
    });

    test('honors phrase queries', () async {
      final index = await seed({
        'n1': ('Patch', 'These are the release notes for v2.'),
        'n2': ('Other', 'Notes about a release party.'),
      });
      final hits = await index.search('"release notes"');
      expect(hits, hasLength(1));
      expect(hits.single.id, 'n1');
    });

    test('honors prefix queries', () async {
      final index = await seed({
        'n1': ('Doc', 'architecture decisions'),
        'n2': ('Doc', 'archive of papers'),
        'n3': ('Doc', 'unrelated text'),
      });
      final hits = await index.search('archi*');
      expect(hits.map((h) => h.id), containsAll(['n1', 'n2']));
      expect(hits.map((h) => h.id), isNot(contains('n3')));
    });

    test('throws InvalidSearchQueryException on bad FTS5 syntax', () async {
      final index = await _open(tmp);
      addTearDown(index.close);
      index.upsert(
        id: 'n1',
        title: 'Hi',
        content: 'hello',
        updatedAt: _testStamp,
      );

      await expectLater(
        index.search('"unterminated'),
        throwsA(isA<InvalidSearchQueryException>()),
      );
    });

    test(
      'tolerates trailing punctuation that breaks raw FTS5 syntax',
      () async {
        final index = await seed({
          'n1': ('Note', 'Siehst du meine Notes heute?'),
        });
        expect(await index.search('Siehst du meine Notes?'), hasLength(1));
      },
    );

    test('tolerates apostrophes that break raw FTS5 syntax', () async {
      final index = await seed({'n1': ('Note', "That's the test note.")});
      expect(await index.search("That's the test"), hasLength(1));
    });

    test(
      'logs a warning naming the bad query on invalid FTS5 syntax',
      () async {
        final logger = Logger.detached('search-test')..level = Level.ALL;
        final index = await _open(tmp, logger: logger);
        addTearDown(index.close);
        // Attached after open() so its own bootstrap logging (e.g. "search.db
        // missing, rebuilding from storage") isn't captured alongside the
        // warning search() logs below.
        final records = <LogRecord>[];
        final sub = logger.onRecord.listen(records.add);
        addTearDown(sub.cancel);

        await expectLater(
          index.search('"unterminated'),
          throwsA(isA<InvalidSearchQueryException>()),
        );

        expect(records, isNotEmpty);
        expect(records.single.level, Level.WARNING);
        expect(records.single.message, contains('unterminated'));
      },
    );

    test('starts a search.query span naming the hit count', () async {
      final processor = _RecordingSpanProcessor();
      final tracer = SdkTracer(
        name: 'test',
        version: null,
        processor: processor,
      );
      final index = await _open(tmp, tracer: tracer)
        ..upsert(
          id: 'n1',
          title: 'Hi',
          content: 'hello world',
          updatedAt: _testStamp,
        );
      addTearDown(index.close);

      await index.search('hello');

      final span = processor.ended.single;
      expect(span.name, 'search.query');
      expect(span.attributes['search.hit_count'], 1);
      expect(span.statusCode, StatusCode.unset);
    });

    test('sets an error status on the span for an invalid query', () async {
      final processor = _RecordingSpanProcessor();
      final tracer = SdkTracer(
        name: 'test',
        version: null,
        processor: processor,
      );
      final index = await _open(tmp, tracer: tracer);
      addTearDown(index.close);

      await expectLater(
        index.search('"unterminated'),
        throwsA(isA<InvalidSearchQueryException>()),
      );

      expect(processor.ended.single.statusCode, StatusCode.error);
    });

    test(
      'returns id, title, snippet, rank; rows ordered by rank ascending',
      () async {
        final index = await seed({
          'n1': ('Just one mention', 'kangaroo'),
          'n2': (
            'Many kangaroo mentions',
            'kangaroo kangaroo kangaroo plays in the field',
          ),
        });

        final hits = await index.search('kangaroo');
        expect(hits, hasLength(2));
        // bm25 returns ascending rank where the first row is most relevant.
        expect(hits.first.id, 'n2');
        expect(hits.last.id, 'n1');
        for (final h in hits) {
          expect(h.id, isNotEmpty);
          expect(h.title, isNotEmpty);
          expect(h.snippet, isNotEmpty);
          expect(h.rank, isA<double>());
        }
        // Ascending: first <= last
        expect(hits.first.rank, lessThanOrEqualTo(hits.last.rank));
      },
    );

    test('returns the updatedAt passed to upsert', () async {
      final index = await _open(tmp);
      addTearDown(index.close);
      final stamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
      index.upsert(
        id: 'n1',
        title: 'Doc',
        content: 'kangaroo',
        updatedAt: stamp,
      );

      final hits = await index.search('kangaroo');
      expect(hits.single.updatedAt, stamp);
    });

    test('snippet wraps matches with <mark>...</mark>', () async {
      final index = await seed({
        'n1': ('Doc', 'The quick brown fox jumps over the lazy dog.'),
      });
      final hits = await index.search('fox');
      expect(hits, hasLength(1));
      expect(hits.single.snippet, contains('<mark>'));
      expect(hits.single.snippet, contains('</mark>'));
    });

    test('respects the limit argument', () async {
      final index = await _open(tmp);
      addTearDown(index.close);
      for (var i = 0; i < 10; i++) {
        index.upsert(
          id: 'n$i',
          title: 't$i',
          content: 'orbit',
          updatedAt: _testStamp,
        );
      }
      expect(await index.search('orbit', limit: 3), hasLength(3));
    });
  });

  group('SearchIndex.search hybrid ranking', () {
    test('stays BM25-only ordered when no provider is configured', () async {
      final index = await _open(tmp);
      addTearDown(index.close);
      index
        ..upsert(
          id: 'weak',
          title: 'Weak match',
          content: 'apple mentioned once',
          updatedAt: _testStamp,
        )
        ..upsert(
          id: 'strong',
          title: 'Strong match',
          content: 'apple apple apple everywhere apple',
          updatedAt: _testStamp,
        );

      final hits = await index.search('apple');

      expect(hits.map((h) => h.id).toList(), ['strong', 'weak']);
    });

    test('calls the embedding provider once with the query text', () async {
      final provider = FakeEmbeddingProvider();
      final index = await _open(tmp, embeddingProvider: provider);
      addTearDown(index.close);
      index.upsert(
        id: 'n1',
        title: 'A',
        content: 'hello world',
        updatedAt: _testStamp,
        embedding: [1.0, 2.0, 3.0, 4.0],
      );

      await index.search('hello');

      expect(provider.callCount, 1);
    });

    test('a note found only via vector similarity is still returned', () async {
      final provider = FakeEmbeddingProvider();
      final index = await _open(tmp, embeddingProvider: provider);
      addTearDown(index.close);

      // "auth" note: matches the query by keyword, far in vector space.
      index
        ..upsert(
          id: 'keyword-match',
          title: 'Auth',
          content: 'the word auth appears here',
          updatedAt: _testStamp,
          embedding: [100.0, 100.0, 100.0, 100.0],
        )
        // "oauth" note: no keyword overlap with "auth", but close in
        // vector space to the query embedding.
        ..upsert(
          id: 'semantic-match',
          title: 'Login redesign',
          content: 'switching to OAuth for third-party login',
          updatedAt: _testStamp,
          embedding: [1.0, 2.0, 3.0, 4.1],
        );
      provider.overrides['auth'] = [1.0, 2.0, 3.0, 4.0];

      final hits = await index.search('auth');

      expect(hits.map((h) => h.id), contains('semantic-match'));
      expect(hits.map((h) => h.id), contains('keyword-match'));
    });

    test('a vector-only hit carries title, path, and a content snippet',
        () async {
      final provider = FakeEmbeddingProvider();
      final index = await _open(tmp, embeddingProvider: provider);
      addTearDown(index.close);

      index.upsert(
        id: 'semantic-match',
        title: 'Login redesign',
        content: 'switching to OAuth for third-party login',
        updatedAt: _testStamp,
        path: 'Projects/Auth',
        embedding: [1.0, 2.0, 3.0, 4.1],
      );
      provider.overrides['auth'] = [1.0, 2.0, 3.0, 4.0];

      final hits = await index.search('auth');

      final hit = hits.singleWhere((h) => h.id == 'semantic-match');
      expect(hit.title, 'Login redesign');
      expect(hit.path, 'Projects/Auth');
      expect(hit.snippet, contains('OAuth'));
    });

    test(
        'falls back to BM25-only results when the provider fails at '
        'query time', () async {
      final provider = FakeEmbeddingProvider()..shouldThrow = true;
      final index = await _open(tmp, embeddingProvider: provider);
      addTearDown(index.close);
      // Seed a vector row directly (bypassing embed(), which always
      // throws for this provider) so there's something a working query
      // could have matched, to prove the fallback is BM25-only.
      index.upsert(
        id: 'n1',
        title: 'A',
        content: 'findable by keyword',
        updatedAt: _testStamp,
        embedding: [1.0, 2.0, 3.0, 4.0],
      );

      final hits = await index.search('findable');

      expect(hits, hasLength(1));
      expect(hits.single.id, 'n1');
    });

    test('respects path/tag filters for vector-only hits too', () async {
      final provider = FakeEmbeddingProvider();
      final index = await _open(tmp, embeddingProvider: provider);
      addTearDown(index.close);

      index
        ..upsert(
          id: 'in-scope',
          title: 'In scope',
          content: 'switching to OAuth for third-party login',
          updatedAt: _testStamp,
          path: 'Projects/Alpha',
          embedding: [1.0, 2.0, 3.0, 4.1],
        )
        ..upsert(
          id: 'out-of-scope',
          title: 'Out of scope',
          content: 'switching to OAuth for third-party login too',
          updatedAt: _testStamp,
          path: 'Elsewhere',
          embedding: [1.0, 2.0, 3.0, 4.2],
        );
      provider.overrides['auth'] = [1.0, 2.0, 3.0, 4.0];

      final hits = await index.search('auth', path: 'Projects/Alpha');

      expect(hits.map((h) => h.id).toList(), ['in-scope']);
    });

    test(
        'a limit above the fusion candidate size still returns that many '
        'hits when the provider is unreachable', () async {
      const noteCount = 120;
      const limit = 100;

      final noProvider = await _open(tmp);
      for (var i = 0; i < noteCount; i++) {
        noProvider.upsert(
          id: 'note-$i',
          title: 'Note $i',
          content: 'findable content $i',
          updatedAt: _testStamp,
        );
      }
      final baselineHits = await noProvider.search('findable', limit: limit);
      noProvider.close();

      final failingProvider = FakeEmbeddingProvider()..shouldThrow = true;
      final withProvider = await _open(
        tmp,
        embeddingProvider: failingProvider,
        forceRebuild: true,
      );
      addTearDown(withProvider.close);
      for (var i = 0; i < noteCount; i++) {
        withProvider.upsert(
          id: 'note-$i',
          title: 'Note $i',
          content: 'findable content $i',
          updatedAt: _testStamp,
        );
      }

      final hits = await withProvider.search('findable', limit: limit);

      expect(hits, hasLength(baselineHits.length));
      expect(hits, hasLength(limit));
    });
  });

  group('SearchIndex.backfillEmbeddings', () {
    test('computes and stores embeddings for notes that lack one', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: 'aardvark');
      await storage.create(title: 'B', content: 'bumblebee');
      final provider = FakeEmbeddingProvider();
      // Opening with a provider on a fresh vault rebuilds notes_fts (via
      // scanning storage) but backfill is a separate call — this proves
      // 7.1's "identify ids missing an embedding" against real rebuilt
      // rows, not hand-seeded ones. autoBackfill: false so open()'s own
      // automatic pass doesn't race the explicit call below.
      final index = await _open(
        tmp,
        storage: storage,
        embeddingProvider: provider,
        autoBackfill: false,
      );
      addTearDown(index.close);

      await index.backfillEmbeddings(sleep: (_) async {});

      final db = sqlite3.open(_dbFile(tmp).path);
      final count = db.select('SELECT COUNT(*) AS c FROM note_vectors;');
      db.close();
      expect(count.single['c'], 2);
    });

    test("embeds each note's title together with its content", () async {
      final storage = _storage(tmp);
      await storage.create(title: 'Melanie', content: 'Met at the conference.');
      await storage.create(title: 'Blank body', content: '');
      final provider = FakeEmbeddingProvider();
      final index = await _open(
        tmp,
        storage: storage,
        embeddingProvider: provider,
        autoBackfill: false,
      );
      addTearDown(index.close);

      await index.backfillEmbeddings(sleep: (_) async {});

      expect(
        provider.inputs,
        unorderedEquals(['Melanie\n\nMet at the conference.', 'Blank body']),
      );
      final db = sqlite3.open(_dbFile(tmp).path);
      final count = db.select('SELECT COUNT(*) AS c FROM note_vectors;');
      db.close();
      // The blank-bodied note still gets a vector, from its title.
      expect(count.single['c'], 2);
    });

    test('processes ids in batches, sleeping between (not within) batches',
        () async {
      final storage = _storage(tmp);
      for (var i = 0; i < 25; i++) {
        await storage.create(title: 'n$i', content: 'content $i');
      }
      final provider = FakeEmbeddingProvider();
      final index = await _open(
        tmp,
        storage: storage,
        embeddingProvider: provider,
        autoBackfill: false,
      );
      addTearDown(index.close);
      final sleepCalls = <Duration>[];

      await index.backfillEmbeddings(
        sleep: (d) async {
          sleepCalls.add(d);
        },
      );

      // 25 ids / batch size 10 -> 3 batches -> 2 gaps between them.
      expect(sleepCalls, hasLength(2));
      expect(provider.callCount, 25);
    });

    test('does nothing when no provider is configured', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: 'aardvark');
      final index = await _open(tmp, storage: storage);
      addTearDown(index.close);

      await index.backfillEmbeddings();

      expect(_hasVectorTable(tmp), isFalse);
    });
  });

  group('SearchIndex startup backfill', () {
    test('open() does not block on backfill completing', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: 'aardvark');
      final gate = Completer<void>();
      final provider = _GatedEmbeddingProvider(gate.future);

      // If open() awaited backfill to completion, this would hang forever
      // since `gate` is never completed.
      final index =
          await _open(tmp, storage: storage, embeddingProvider: provider)
              .timeout(const Duration(seconds: 5));
      addTearDown(index.close);

      expect(index.pendingBackfill, isNotNull);
      gate.complete();
      await index.pendingBackfill;
    });

    test(
        'a note with a pending (not-yet-backfilled) embedding is still '
        'findable via BM25', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: 'aardvark');
      // autoBackfill: false simulates a backfill pass that hasn't run
      // yet (or hasn't reached this note yet) — no note_vectors row
      // exists, but a provider is configured, so search() takes the
      // hybrid path and must not choke on the note's absent embedding.
      final index = await _open(
        tmp,
        storage: storage,
        embeddingProvider: FakeEmbeddingProvider(),
        autoBackfill: false,
      );
      addTearDown(index.close);

      final hits = await index.search('aardvark');

      expect(hits, hasLength(1));
    });
  });
}

/// [EmbeddingProvider] whose `embed()` never resolves until [gate]
/// completes — used to prove startup doesn't wait for backfill.
class _GatedEmbeddingProvider implements EmbeddingProvider {
  _GatedEmbeddingProvider(this.gate);

  final Future<void> gate;

  @override
  int get dimensions => 4;

  @override
  Future<List<double>> embed(String text) async {
    await gate;
    return const [1.0, 2.0, 3.0, 4.0];
  }
}
