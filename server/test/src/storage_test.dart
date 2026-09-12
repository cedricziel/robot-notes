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

    test('finds notes nested under folders, not just at the root', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final root = await storage.create(title: 'Root note', content: '');
      final nested = await storage.create(
        title: 'Nested note',
        content: '',
        path: 'Projects/Alpha',
      );
      final summaries = await storage.list();
      expect(summaries.map((s) => s.id), containsAll([root.id, nested.id]));
      final nestedSummary = summaries.firstWhere((s) => s.id == nested.id);
      expect(nestedSummary.path, 'Projects/Alpha');
    });

    test('summaries carry the computed tag set from content', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final note = await storage.create(
        title: 'Tagged',
        content: 'remember #urgent work',
      );
      final summaries = await storage.list();
      final summary = summaries.firstWhere((s) => s.id == note.id);
      expect(summary.tags, {'urgent'});
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
      expect(note.path, '');
      expect(note.id.length, 26);
      expect(note.createdAt, note.updatedAt);

      final file = File('${tmp.path}/content/Hello.md');
      expect(file.existsSync(), isTrue);
      final fm = parseFrontmatter(file.readAsStringSync());
      expect(fm.metadata['id'], note.id);
      expect(fm.metadata['title'], 'Hello');
      expect(fm.metadata['path'], '');
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

    test('writes nested notes under their folder', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final note = await storage.create(
        title: 'Meeting Notes',
        content: 'agenda',
        path: 'Projects/Alpha',
      );
      expect(note.path, 'Projects/Alpha');
      final file = File(
        '${tmp.path}/content/Projects/Alpha/Meeting Notes.md',
      );
      expect(file.existsSync(), isTrue);
    });

    test('rejects a title colliding with an existing note at the same path',
        () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      await storage.create(title: 'Ideas', content: '');
      expect(
        () => storage.create(title: 'Ideas', content: ''),
        throwsA(isA<PathConflictException>()),
      );
    });

    test('collision detection is case-insensitive', () async {
      final storage = _storage(
        tmp,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      await storage.create(title: 'Ideas', content: '');
      expect(
        () => storage.create(title: 'ideas', content: ''),
        throwsA(isA<PathConflictException>()),
      );
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

    test('finds a note by id after a fresh Storage instance scans the disk',
        () async {
      final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
      final first = _storage(tmp, clock: clock);
      final created = await first.create(
        title: 'Persisted',
        content: 'c',
        path: 'Folder',
      );

      // A brand-new Storage instance (simulating a server restart) has an
      // empty in-memory cache and must locate the note by scanning disk.
      final second = _storage(tmp, clock: clock);
      final read = await second.read(created.id);
      expect(read.title, 'Persisted');
      expect(read.path, 'Folder');
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
      final path = '${tmp.path}/content/A.md';
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
      final reread = File('${tmp.path}/content/B.md').readAsStringSync();
      expect(reread, contains('tags:'));
      expect(reread, contains('"planning"'));
    });

    group('title/path changes move or rename the file', () {
      test('title change renames the file within the same folder', () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final v1 = await storage.create(title: 'Draft', content: 'c');
        await storage.update(
          id: v1.id,
          title: 'Final',
          content: 'c',
          ifMatch: 1,
        );
        expect(File('${tmp.path}/content/Final.md').existsSync(), isTrue);
        expect(File('${tmp.path}/content/Draft.md').existsSync(), isFalse);
      });

      test('path change moves the file to the new folder', () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final v1 = await storage.create(title: 'Inbox', content: 'c');
        final updated = await storage.update(
          id: v1.id,
          title: 'Inbox',
          content: 'c',
          ifMatch: 1,
          path: 'Projects/Alpha',
        );
        expect(updated.path, 'Projects/Alpha');
        expect(
          File(
            '${tmp.path}/content/Projects/Alpha/Inbox.md',
          ).existsSync(),
          isTrue,
        );
        expect(File('${tmp.path}/content/Inbox.md').existsSync(), isFalse);
      });

      test('omitting path leaves the folder unchanged', () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final v1 = await storage.create(
          title: 'Note',
          content: 'c',
          path: 'Folder',
        );
        final updated = await storage.update(
          id: v1.id,
          title: 'Note',
          content: 'c2',
          ifMatch: 1,
        );
        expect(updated.path, 'Folder');
      });

      test('moving a note out of a folder leaves the now-empty folder',
          () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final v1 = await storage.create(
          title: 'Lonely',
          content: 'c',
          path: 'Projects/Alpha',
        );
        await storage.update(
          id: v1.id,
          title: 'Lonely',
          content: 'c',
          ifMatch: 1,
          path: '',
        );
        expect(
          Directory('${tmp.path}/content/Projects/Alpha').existsSync(),
          isTrue,
        );
      });

      test(
          'renaming into an existing title is rejected and both files '
          'are left unchanged', () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        await storage.create(title: 'A', content: 'a-content');
        final b = await storage.create(title: 'B', content: 'b-content');
        await expectLater(
          storage.update(id: b.id, title: 'A', content: 'x', ifMatch: 1),
          throwsA(isA<PathConflictException>()),
        );
        expect(
          File('${tmp.path}/content/A.md').readAsStringSync(),
          contains('a-content'),
        );
        expect(
          File('${tmp.path}/content/B.md').readAsStringSync(),
          contains('b-content'),
        );
      });

      test('renaming a note to its own current title/path is a no-op move',
          () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final v1 = await storage.create(title: 'Same', content: 'c1');
        final v2 = await storage.update(
          id: v1.id,
          title: 'Same',
          content: 'c2',
          ifMatch: 1,
        );
        expect(v2.version, 2);
        expect(File('${tmp.path}/content/Same.md').existsSync(), isTrue);
      });

      test(
          'two concurrent renames to the same target path: exactly one '
          'succeeds, the other gets PathConflict, neither file is lost',
          () async {
        final storage = _storage(
          tmp,
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        );
        final b = await storage.create(title: 'B', content: 'b-content');
        final c = await storage.create(title: 'C', content: 'c-content');

        final results = await Future.wait<Object>([
          storage
              .update(
                id: b.id,
                title: 'Target',
                content: 'b-content',
                ifMatch: 1,
              )
              .then<Object>((n) => n)
              .catchError((Object e) => e),
          storage
              .update(
                id: c.id,
                title: 'Target',
                content: 'c-content',
                ifMatch: 1,
              )
              .then<Object>((n) => n)
              .catchError((Object e) => e),
        ]);

        final successes = results.whereType<StoredNote>().toList();
        final conflicts = results.whereType<PathConflictException>().toList();
        expect(successes.length, 1);
        expect(conflicts.length, 1);

        // Exactly one file exists at the target; the loser's original
        // content is still readable from wherever it ended up (its own
        // file was never touched, since the write only ever happens
        // after the collision check).
        expect(File('${tmp.path}/content/Target.md').existsSync(), isTrue);
        final survivingContent =
            File('${tmp.path}/content/Target.md').readAsStringSync();
        expect(
          survivingContent,
          anyOf(contains('b-content'), contains('c-content')),
        );

        // The loser's own original file must still exist (it was never
        // renamed away, since the whole point is its write never ran).
        final loserId = conflicts.isNotEmpty
            ? (successes.single.id == b.id ? c.id : b.id)
            : null;
        if (loserId == c.id) {
          expect(File('${tmp.path}/content/C.md').existsSync(), isTrue);
        } else {
          expect(File('${tmp.path}/content/B.md').existsSync(), isTrue);
        }
      });
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
      expect(File('${tmp.path}/content/A.md').existsSync(), isFalse);
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
      File('${tmp.path}/content/A.md.tmp').writeAsStringSync(
        '---\nid: ${v1.id}\ntitle: ghost\npath: ""\nversion: 999\n'
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

  group('StoredNote.toSummary', () {
    StoredNote note({
      required String content,
      Map<String, Object?> extra = const {},
    }) {
      final now = DateTime.utc(2026, 4, 25, 10);
      return StoredNote(
        id: '01HXY0000000000000000000',
        title: 'Weekend Trip',
        path: '',
        version: 1,
        createdAt: now,
        updatedAt: now,
        content: content,
        extra: extra,
      );
    }

    test('populates excerpt from content via computeExcerpt', () {
      final summary = note(
        content: '# Weekend Trip\nLeaving Friday, back Sunday.',
      ).toSummary();
      expect(summary.excerpt, 'Weekend Trip Leaving Friday, back Sunday.');
    });

    test('excerpt is empty for empty content', () {
      expect(note(content: '').toSummary().excerpt, '');
    });
  });
}
