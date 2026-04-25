import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-meta-index-test-');
}

NoteSummary _summary(String id, {int version = 1, String title = 't'}) {
  final t = DateTime.utc(2026, 4, 25, 10);
  return NoteSummary(
    id: id,
    title: title,
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
}
