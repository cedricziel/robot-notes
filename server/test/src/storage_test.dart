import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-storage-test-');
}

Storage _storage(Directory dir, {Clock? clock, NoteId Function()? idGen}) {
  return Storage(
    contentDir: Directory('${dir.path}/content'),
    clock: clock ?? const Clock(),
    idGenerator: idGen,
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

  group('Storage.list', () {
    test('returns an empty list when content dir does not exist', () async {
      final storage = _storage(tmp);
      expect(await storage.list(), isEmpty);
    });

    test('returns an empty list when content dir is empty', () async {
      final storage = _storage(tmp);
      Directory('${tmp.path}/content').createSync();
      expect(await storage.list(), isEmpty);
    });

    test('skips and logs malformed files instead of throwing', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final created = await storage.create(title: 'Good', content: 'ok');
      // Sneak a broken note alongside the good one.
      const brokenId = '01XBROKENXX0000000000000XX';
      File('${tmp.path}/content/$brokenId.md').writeAsStringSync(
        '---\nid: $brokenId\ntitle: bad\nbroken yaml: [\n---\n',
      );
      final summaries = await storage.list();
      expect(summaries.map((s) => s.id), [created.id]);
    });
  });

  group('Storage.create', () {
    test('writes a file with required frontmatter and version 1', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final note = await storage.create(
        title: 'Hello',
        content: '# heading\n\nbody\n',
      );
      expect(note.version, 1);
      expect(note.title, 'Hello');
      expect(note.id.length, 26);
      expect(note.createdAt, note.updatedAt);

      final file = File('${tmp.path}/content/${note.id}.md');
      expect(file.existsSync(), isTrue);
      final fm = parseFrontmatter(file.readAsStringSync());
      expect(fm.metadata['id'], note.id);
      expect(fm.metadata['title'], 'Hello');
      expect(fm.metadata['version'], 1);
      expect(fm.metadata['created_at'], note.createdAt.toIso8601String());
      expect(fm.metadata['updated_at'], note.updatedAt.toIso8601String());
      expect(fm.body, '# heading\n\nbody\n');
    });

    test('uses ULID-shaped ids that sort by creation order', () async {
      final ids = <String>[];
      var counter = 0;
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        idGen: () => ('A' * 26).replaceRange(25, 26, '${counter++}'),
      );
      for (var i = 0; i < 3; i++) {
        ids.add((await storage.create(title: 't$i', content: '')).id);
      }
      final sorted = [...ids]..sort();
      expect(ids, sorted);
    });
  });

  group('Storage.read', () {
    test('returns the parsed note', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final created = await storage.create(title: 'A', content: 'body');
      final read = await storage.read(created.id);
      expect(read.id, created.id);
      expect(read.title, 'A');
      expect(read.version, 1);
      expect(read.content, 'body');
    });

    test('throws NoteNotFoundException for unknown id', () async {
      final storage = _storage(tmp);
      expect(
        () => storage.read('01ZZZZZZZZZZZZZZZZZZZZZZZZ'),
        throwsA(isA<NoteNotFoundException>()),
      );
    });
  });

  group('Storage.update', () {
    test('bumps version, refreshes updated_at, preserves created_at', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 11),
      ]);
      final storage = _storage(tmp, clock: clock);
      final v1 = await storage.create(title: 'A', content: 'c1');
      final v2 = await storage.update(
        id: v1.id,
        title: 'B',
        content: 'c2',
        ifMatch: 1,
      );
      expect(v2.version, 2);
      expect(v2.title, 'B');
      expect(v2.content, 'c2');
      expect(v2.createdAt, v1.createdAt);
      expect(v2.updatedAt.isAfter(v1.updatedAt), isTrue);
    });

    test('throws VersionConflict with current state on stale ifMatch',
        () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final v1 = await storage.create(title: 'A', content: 'c1');
      try {
        await storage.update(id: v1.id, title: 'B', content: 'c2', ifMatch: 99);
        fail('expected VersionConflictException');
      } on VersionConflictException catch (e) {
        expect(e.current.id, v1.id);
        expect(e.current.version, 1);
        expect(e.suppliedIfMatch, 99);
      }
    });

    test('throws NoteNotFound for unknown id', () async {
      final storage = _storage(tmp);
      expect(
        () => storage.update(
          id: '01ZZZZZZZZZZZZZZZZZZZZZZZZ',
          title: 't',
          content: 'c',
          ifMatch: 1,
        ),
        throwsA(isA<NoteNotFoundException>()),
      );
    });

    test('preserves unknown frontmatter keys across updates', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final v1 = await storage.create(title: 'A', content: 'c1');
      // Inject an extra key directly into the file, simulating an external
      // tool or a future schema field.
      final path = '${tmp.path}/content/${v1.id}.md';
      final raw = File(path).readAsStringSync();
      File(path).writeAsStringSync(
        raw.replaceFirst(
          'updated_at: ',
          'tags:\n  - "planning"\n  - "ideas"\nupdated_at: ',
        ),
      );
      final v2 = await storage.update(
        id: v1.id,
        title: 'B',
        content: 'c2',
        ifMatch: 1,
      );
      expect(v2.extra['tags'], ['planning', 'ideas']);
      final reread = File(path).readAsStringSync();
      expect(reread, contains('tags:'));
      expect(reread, contains('"planning"'));
    });
  });

  group('Storage.delete', () {
    test('removes the file', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final v1 = await storage.create(title: 'A', content: 'c');
      await storage.delete(v1.id);
      expect(File('${tmp.path}/content/${v1.id}.md').existsSync(), isFalse);
    });

    test('throws NoteNotFound for unknown id', () async {
      final storage = _storage(tmp);
      expect(
        () => storage.delete('01ZZZZZZZZZZZZZZZZZZZZZZZZ'),
        throwsA(isA<NoteNotFoundException>()),
      );
    });
  });

  group('Storage atomicity', () {
    test('writes do not leave .tmp files in place after success', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      await storage.create(title: 'a', content: 'b');
      await storage.create(title: 'c', content: 'd');
      final tmpFiles = Directory('${tmp.path}/content')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'));
      expect(tmpFiles, isEmpty);
    });

    test('a stray .tmp from a prior crash does not corrupt reads', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final v1 = await storage.create(title: 'A', content: 'c1');
      // Simulate an interrupted write: the writer flushed the tmp file but
      // crashed before the rename. The canonical file is untouched.
      File('${tmp.path}/content/${v1.id}.md.tmp').writeAsStringSync(
        '---\nid: ${v1.id}\ntitle: ghost\nversion: 999\n'
        'created_at: 2026-04-25T10:00:00.000Z\n'
        'updated_at: 2026-04-25T10:00:00.000Z\n---\nghost body\n',
      );
      final read = await storage.read(v1.id);
      expect(read.title, 'A');
      expect(read.version, 1);
    });
  });

  group('Storage concurrency', () {
    test('serializes concurrent updates against the same id', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 11),
        DateTime.utc(2026, 4, 25, 12),
        DateTime.utc(2026, 4, 25, 13),
      ]);
      final storage = _storage(tmp, clock: clock);
      final v1 = await storage.create(title: 'A', content: 'c0');

      // Start three updates back-to-back without awaiting; only the first
      // should match ifMatch=1, the rest should observe the bumped version.
      final results = await Future.wait<Object>([
        storage
            .update(id: v1.id, title: 'A1', content: 'c1', ifMatch: 1)
            .then<Object>((n) => n)
            .catchError((Object e) => e),
        storage
            .update(id: v1.id, title: 'A2', content: 'c2', ifMatch: 1)
            .then<Object>((n) => n)
            .catchError((Object e) => e),
        storage
            .update(id: v1.id, title: 'A3', content: 'c3', ifMatch: 1)
            .then<Object>((n) => n)
            .catchError((Object e) => e),
      ]);

      final successes = results.whereType<StoredNote>().toList();
      final conflicts = results.whereType<VersionConflictException>().toList();
      expect(successes.length, 1);
      expect(conflicts.length, 2);
      // The successful write must land at version 2 (no torn writes).
      expect(successes.single.version, 2);
      final onDisk = await storage.read(v1.id);
      expect(onDisk.version, 2);
    });

    test('updates on different ids do not block each other', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final a = await storage.create(title: 'A', content: 'a');
      final b = await storage.create(title: 'B', content: 'b');
      // Issue two concurrent updates on different ids.
      final futures = await Future.wait([
        storage.update(id: a.id, title: 'A', content: 'a2', ifMatch: 1),
        storage.update(id: b.id, title: 'B', content: 'b2', ifMatch: 1),
      ]);
      expect(futures.map((n) => n.version), [2, 2]);
    });
  });
}
