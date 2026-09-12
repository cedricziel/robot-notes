import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-meta-index-test-');
}

NoteSummary _summary(
  String id, {
  int version = 1,
  String title = 't',
  String path = '',
}) {
  final t = DateTime.utc(2026, 4, 25, 10);
  return NoteSummary(
    id: id,
    title: title,
    path: path,
    version: version,
    createdAt: t,
    updatedAt: t,
  );
}

void main() {
  group('MetaIndex.scan', () {
    late Directory tmp;

    setUp(() {
      tmp = _tempDir();
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('populates entries from a Storage backed by real files', () async {
      var counter = 0;
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5F${String.fromCharCode(
          0x41 + counter++,
        )}1',
      );
      final a = await storage.create(title: 'a', content: '');
      final b = await storage.create(title: 'b', content: '');
      final c = await storage.create(title: 'c', content: '');

      final index = MetaIndex();
      final loaded = await index.scan(storage);
      expect(loaded, 3);
      expect(index.length, 3);
      expect(index.get(a.id)?.title, 'a');
      expect(index.get(b.id)?.title, 'b');
      expect(index.get(c.id)?.title, 'c');
    });

    test('skips malformed files without throwing', () async {
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final ok = await storage.create(title: 'good', content: '');
      File(
        '${tmp.path}/content/01XBROKENXX0000000000000XX.md',
      ).writeAsStringSync('---\nbroken: [\n---\n');
      final index = MetaIndex();
      final loaded = await index.scan(storage);
      expect(loaded, 1);
      expect(index.get(ok.id), isNotNull);
    });
  });

  group('MetaIndex mutations', () {
    test('upsert reflects new metadata immediately', () {
      final index = MetaIndex()..upsert(_summary('A', title: 'first'));
      expect(index.get('A')?.title, 'first');
      index.upsert(_summary('A', title: 'second', version: 2));
      expect(index.get('A')?.title, 'second');
      expect(index.get('A')?.version, 2);
      expect(index.length, 1);
    });

    test('remove deletes the entry', () {
      final index = MetaIndex()
        ..upsert(_summary('A'))
        ..upsert(_summary('B'));
      expect(index.length, 2);
      index.remove('A');
      expect(index.length, 1);
      expect(index.get('A'), isNull);
      expect(index.get('B'), isNotNull);
    });

    test('remove on missing id is a no-op', () {
      final index = MetaIndex();
      expect(() => index.remove('NOPE'), returnsNormally);
    });
  });

  group('MetaIndex.page', () {
    MetaIndex seeded(int count) {
      final idx = MetaIndex();
      // Use predictable ids so cursor math is easy to read.
      for (var i = 0; i < count; i++) {
        idx.upsert(_summary('id_${i.toString().padLeft(3, '0')}'));
      }
      return idx;
    }

    test('returns ascending ids and a cursor when more remain', () {
      final idx = seeded(5);
      final p1 = idx.page(limit: 2);
      expect(p1.items.map((s) => s.id), ['id_000', 'id_001']);
      expect(p1.nextCursor, 'id_001');
    });

    test('walks the full index across pages', () {
      final idx = seeded(5);
      String? cursor;
      final collected = <String>[];
      for (var loop = 0; loop < 10; loop++) {
        final page = idx.page(after: cursor, limit: 2);
        collected.addAll(page.items.map((s) => s.id));
        if (page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      expect(collected, [
        'id_000',
        'id_001',
        'id_002',
        'id_003',
        'id_004',
      ]);
    });

    test('final page returns null nextCursor', () {
      final idx = seeded(3);
      final page = idx.page(limit: 10);
      expect(page.items.length, 3);
      expect(page.nextCursor, isNull);
    });

    test('clamps limit to kMaxPageSize', () {
      final idx = seeded(kMaxPageSize + 50);
      final page = idx.page(limit: kMaxPageSize + 50);
      expect(page.items.length, kMaxPageSize);
    });

    test('after that is not in the index resumes at the next id', () {
      final idx = MetaIndex()
        ..upsert(_summary('A'))
        ..upsert(_summary('C'))
        ..upsert(_summary('E'));
      // 'B' is not in the index; the page should start at 'C'.
      final page = idx.page(after: 'B', limit: 10);
      expect(page.items.map((s) => s.id), ['C', 'E']);
    });

    test('empty index returns empty page with null cursor', () {
      final page = MetaIndex().page();
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });
  });

  group('MetaIndex.page sort=updated_desc', () {
    NoteSummary at(String id, DateTime updatedAt, {String path = ''}) =>
        NoteSummary(
          id: id,
          title: id,
          path: path,
          version: 1,
          createdAt: updatedAt,
          updatedAt: updatedAt,
        );

    test('returns newest-updated-first', () {
      final idx = MetaIndex()
        ..upsert(at('A', DateTime.utc(2026)))
        ..upsert(at('B', DateTime.utc(2026, 1, 3)))
        ..upsert(at('C', DateTime.utc(2026, 1, 2)));

      final page = idx.page(sort: 'updated_desc', limit: 10);

      expect(page.items.map((s) => s.id), ['B', 'C', 'A']);
      expect(page.nextCursor, isNull);
    });

    test('ties on updated_at break by id descending', () {
      final t = DateTime.utc(2026);
      final idx = MetaIndex()
        ..upsert(at('A', t))
        ..upsert(at('B', t))
        ..upsert(at('C', t));

      final page = idx.page(sort: 'updated_desc', limit: 10);

      expect(page.items.map((s) => s.id), ['C', 'B', 'A']);
    });

    test('walks the full index across pages via cursor', () {
      final idx = MetaIndex()
        ..upsert(at('A', DateTime.utc(2026)))
        ..upsert(at('B', DateTime.utc(2026, 1, 3)))
        ..upsert(at('C', DateTime.utc(2026, 1, 2)));

      String? cursor;
      final collected = <String>[];
      for (var loop = 0; loop < 10; loop++) {
        final page = idx.page(sort: 'updated_desc', after: cursor, limit: 1);
        collected.addAll(page.items.map((s) => s.id));
        if (page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      expect(collected, ['B', 'C', 'A']);
    });

    test(
        'an already-seen note that jumps to the top is not revisited by '
        'an in-flight pagination walk', () {
      final idx = MetaIndex()
        ..upsert(at('A', DateTime.utc(2026)))
        ..upsert(at('B', DateTime.utc(2026, 1, 2)));

      final page1 = idx.page(sort: 'updated_desc', limit: 1);
      expect(page1.items.single.id, 'B');

      // 'A' is updated after page1 was fetched, jumping above the cursor.
      idx.upsert(at('A', DateTime.utc(2026, 1, 3)));

      final page2 = idx.page(
        sort: 'updated_desc',
        after: page1.nextCursor,
        limit: 10,
      );
      // Keyset pagination is stable relative to the cursor position, not
      // a live top-N snapshot: an entry that moved above the cursor is
      // not re-surfaced by resuming the walk.
      expect(page2.items, isEmpty);
    });

    test('cursor is opaque and differs from the plain id', () {
      final idx = MetaIndex()
        ..upsert(at('A', DateTime.utc(2026)))
        ..upsert(at('B', DateTime.utc(2026, 1, 2)));
      final page = idx.page(sort: 'updated_desc', limit: 1);
      expect(page.nextCursor, isNot('A'));
    });

    test('final page returns null nextCursor', () {
      final idx = MetaIndex()
        ..upsert(at('A', DateTime.utc(2026)))
        ..upsert(at('B', DateTime.utc(2026, 1, 2)));
      final page = idx.page(sort: 'updated_desc', limit: 10);
      expect(page.nextCursor, isNull);
    });

    test('malformed cursor throws InvalidCursorException', () {
      final idx = MetaIndex()..upsert(at('A', DateTime.utc(2026)));
      expect(
        () => idx.page(sort: 'updated_desc', after: 'not-valid-base64!!'),
        throwsA(isA<InvalidCursorException>()),
      );
    });
  });

  group('MetaIndex.page pathPrefix filter', () {
    test('null pathPrefix returns everything (default sort)', () {
      final idx = MetaIndex()
        ..upsert(_summary('A'))
        ..upsert(_summary('B', path: 'Projects/Alpha'));
      final page = idx.page(limit: 10);
      expect(page.items.map((s) => s.id), ['A', 'B']);
    });

    test('exact path match is included', () {
      final idx = MetaIndex()
        ..upsert(_summary('A', path: 'Projects/Alpha'))
        ..upsert(_summary('B', path: 'Projects/Beta'));
      final page = idx.page(limit: 10, pathPrefix: 'Projects/Alpha');
      expect(page.items.map((s) => s.id), ['A']);
    });

    test('nested descendant is included, sibling is not', () {
      final idx = MetaIndex()
        ..upsert(_summary('A', path: 'Projects/Alpha/Sub'))
        ..upsert(_summary('B', path: 'Projects/Beta'))
        ..upsert(_summary('C'));
      final page = idx.page(limit: 10, pathPrefix: 'Projects/Alpha');
      expect(page.items.map((s) => s.id), ['A']);
    });

    test(
        'a folder name that is a prefix but not a path segment boundary '
        'is excluded', () {
      final idx = MetaIndex()
        ..upsert(_summary('A', path: 'Projects/AlphaExtra'))
        ..upsert(_summary('B', path: 'Projects/Alpha'));
      final page = idx.page(limit: 10, pathPrefix: 'Projects/Alpha');
      expect(page.items.map((s) => s.id), ['B']);
    });

    test('pagination composes with the filter (sort=id)', () {
      final idx = MetaIndex()
        ..upsert(_summary('A', path: 'Folder'))
        ..upsert(_summary('B'))
        ..upsert(_summary('C', path: 'Folder'))
        ..upsert(_summary('D', path: 'Folder'));
      final p1 = idx.page(limit: 2, pathPrefix: 'Folder');
      expect(p1.items.map((s) => s.id), ['A', 'C']);
      expect(p1.nextCursor, 'C');
      final p2 = idx.page(after: p1.nextCursor, limit: 2, pathPrefix: 'Folder');
      expect(p2.items.map((s) => s.id), ['D']);
      expect(p2.nextCursor, isNull);
    });

    test('pagination composes with the filter (sort=updated_desc)', () {
      final now = DateTime.utc(2026);
      final idx = MetaIndex()
        ..upsert(_summary('A', path: 'Folder').copyWithUpdated(now))
        ..upsert(
          _summary('B').copyWithUpdated(now.add(const Duration(minutes: 1))),
        )
        ..upsert(
          _summary(
            'C',
            path: 'Folder',
          ).copyWithUpdated(now.add(const Duration(minutes: 2))),
        );
      final page =
          idx.page(sort: 'updated_desc', limit: 10, pathPrefix: 'Folder');
      expect(page.items.map((s) => s.id), ['C', 'A']);
    });
  });
}

extension _WithUpdated on NoteSummary {
  NoteSummary copyWithUpdated(DateTime updatedAt) => NoteSummary(
        id: id,
        title: title,
        path: path,
        version: version,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}
