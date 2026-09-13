import 'dart:io';

import 'package:flutter_otel_sdk/flutter_otel_sdk.dart' hide LogRecord, Logger;
import 'package:logging/logging.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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

Future<SearchIndex> _open(
  Directory tmp, {
  Storage? storage,
  Logger? logger,
  Tracer? tracer,
  bool forceRebuild = false,
}) {
  return SearchIndex.open(
    dbFile: _dbFile(tmp),
    storage: storage ?? _storage(tmp),
    logger: logger,
    tracer: tracer,
    forceRebuild: forceRebuild,
  );
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
      final hits = index.search('architecture');
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
      expect(index.search('hello'), hasLength(1));
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

      final hits = index.search('durable');
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
      expect(index.search('tokenized'), hasLength(1));
    });

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

      expect(index.search('Tagged', path: 'Projects'), hasLength(1));
      expect(index.search('Tagged', path: 'Elsewhere'), isEmpty);
      expect(index.search('Tagged', tag: 'urgent'), hasLength(1));
      expect(index.search('Tagged', tag: 'later'), isEmpty);

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
        expect(index.search('kept'), hasLength(1));
      },
    );
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
      expect(index.search('kangaroo'), hasLength(1));

      index.upsert(
        id: 'n1',
        title: 'Updated',
        content: 'wallaby hops',
        updatedAt: _testStamp,
      );
      expect(index.search('kangaroo'), isEmpty);
      final hits = index.search('wallaby');
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
      expect(index.search('transient'), hasLength(1));

      index
        ..delete('n1')
        ..delete('n1');
      expect(index.search('transient'), isEmpty);
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

      expect(index.search('budget', path: 'Projects/Alpha'), hasLength(1));
      // 'Projects' is an ancestor folder, so it matches too (nested).
      expect(index.search('budget', path: 'Projects'), hasLength(1));
      expect(index.search('budget', path: 'Other'), isEmpty);
      // Case-insensitive, matching tags.dart's own matching rule.
      expect(index.search('budget', tag: 'urgent'), hasLength(1));
      expect(index.search('budget', tag: 'URGENT'), hasLength(1));
      expect(index.search('budget', tag: 'later'), isEmpty);
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
      expect(index.search('run'), hasLength(1));
      expect(index.search('runs'), hasLength(1));
      expect(index.search('running'), hasLength(1));
    });

    test('matches case-insensitively', () async {
      final index = await seed({'n1': ('Hello', 'The quick brown FOX jumps.')});
      expect(index.search('fox'), hasLength(1));
      expect(index.search('FOX'), hasLength(1));
      expect(index.search('Fox'), hasLength(1));
    });

    test('honors phrase queries', () async {
      final index = await seed({
        'n1': ('Patch', 'These are the release notes for v2.'),
        'n2': ('Other', 'Notes about a release party.'),
      });
      final hits = index.search('"release notes"');
      expect(hits, hasLength(1));
      expect(hits.single.id, 'n1');
    });

    test('honors prefix queries', () async {
      final index = await seed({
        'n1': ('Doc', 'architecture decisions'),
        'n2': ('Doc', 'archive of papers'),
        'n3': ('Doc', 'unrelated text'),
      });
      final hits = index.search('archi*');
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

      expect(
        () => index.search('"unterminated'),
        throwsA(isA<InvalidSearchQueryException>()),
      );
    });

    test(
      'tolerates trailing punctuation that breaks raw FTS5 syntax',
      () async {
        final index = await seed({
          'n1': ('Note', 'Siehst du meine Notes heute?'),
        });
        expect(index.search('Siehst du meine Notes?'), hasLength(1));
      },
    );

    test('tolerates apostrophes that break raw FTS5 syntax', () async {
      final index = await seed({'n1': ('Note', "That's the test note.")});
      expect(index.search("That's the test"), hasLength(1));
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

        expect(
          () => index.search('"unterminated'),
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

      index.search('hello');

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

      expect(
        () => index.search('"unterminated'),
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

        final hits = index.search('kangaroo');
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

      final hits = index.search('kangaroo');
      expect(hits.single.updatedAt, stamp);
    });

    test('snippet wraps matches with <mark>...</mark>', () async {
      final index = await seed({
        'n1': ('Doc', 'The quick brown fox jumps over the lazy dog.'),
      });
      final hits = index.search('fox');
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
      expect(index.search('orbit', limit: 3), hasLength(3));
    });
  });
}
