import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-search-test-');
}

Storage _storage(Directory tmp) =>
    Storage(contentDir: Directory('${tmp.path}/content'));

File _dbFile(Directory tmp) => File('${tmp.path}/search.db');

Future<SearchIndex> _open(
  Directory tmp, {
  Storage? storage,
  Logger? logger,
  bool forceRebuild = false,
}) {
  return SearchIndex.open(
    dbFile: _dbFile(tmp),
    storage: storage ?? _storage(tmp),
    logger: logger,
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
      File('${tmp.path}/content/${note.id}.md').deleteSync();

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
        ..execute(
          "UPDATE meta SET value = '0' WHERE key = 'schema_version';",
        )
        ..dispose();

      final logger = Logger.detached('search-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen((rec) => logged.add(rec.message));

      final index = await _open(tmp, storage: storage, logger: logger);
      addTearDown(index.close);

      expect(
        logged.any((l) => l.contains('schema_version mismatch')),
        isTrue,
      );
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
  });

  group('SearchIndex.upsert / delete', () {
    test('upsert makes a row searchable; replaces on second call', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(id: 'n1', title: 'Original', content: 'kangaroo jumps');
      expect(index.search('kangaroo'), hasLength(1));

      index.upsert(id: 'n1', title: 'Updated', content: 'wallaby hops');
      expect(index.search('kangaroo'), isEmpty);
      final hits = index.search('wallaby');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'Updated');
    });

    test('delete removes a row idempotently', () async {
      final index = await _open(tmp);
      addTearDown(index.close);

      index.upsert(id: 'n1', title: 'Doomed', content: 'transient');
      expect(index.search('transient'), hasLength(1));

      index
        ..delete('n1')
        ..delete('n1');
      expect(index.search('transient'), isEmpty);
    });
  });

  group('SearchIndex.search', () {
    Future<SearchIndex> seed(Map<String, (String, String)> notes) async {
      final index = await _open(tmp);
      notes.forEach((id, tc) {
        index.upsert(id: id, title: tc.$1, content: tc.$2);
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
      final index = await seed({
        'n1': ('Hello', 'The quick brown FOX jumps.'),
      });
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
      index.upsert(id: 'n1', title: 'Hi', content: 'hello');

      expect(
        () => index.search('"unterminated'),
        throwsA(isA<InvalidSearchQueryException>()),
      );
    });

    test('returns id, title, snippet, rank; rows ordered by rank ascending',
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
        index.upsert(id: 'n$i', title: 't$i', content: 'orbit');
      }
      expect(index.search('orbit', limit: 3), hasLength(3));
    });
  });
}
