import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../routes/notes/tree.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required MetaIndex metaIndex,
  Storage? storage,
  Object? jsonBody,
  bool malformedJson = false,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  if (malformedJson) {
    when(req.json).thenThrow(const FormatException('bad json'));
  } else {
    when(req.json).thenAnswer((_) async => jsonBody);
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  if (storage != null) when(() => ctx.read<Storage>()).thenReturn(storage);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-tree-route-test-');

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('lists folders that directly contain notes, with counts', () async {
    final storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    await storage.create(title: 'Root A', content: '');
    await storage.create(title: 'Root B', content: '');
    await storage.create(title: 'Nested', content: '', path: 'Projects/Alpha');
    final index = MetaIndex();
    await index.scan(storage);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final folders = (body['folders'] as List).cast<Map<String, dynamic>>();
    expect(folders, [
      {'path': '', 'note_count': 2, 'file_count': 0},
      {'path': 'Projects/Alpha', 'note_count': 1, 'file_count': 0},
    ]);
  });

  test('an intermediate folder with no direct notes is not listed', () async {
    final storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    // Only "Projects/Alpha" has a note directly; "Projects" itself does
    // not and must not get its own entry.
    await storage.create(title: 'Nested', content: '', path: 'Projects/Alpha');
    final index = MetaIndex();
    await index.scan(storage);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
    );
    final body = await res.json() as Map<String, dynamic>;
    final paths =
        (body['folders'] as List).map((f) => (f as Map)['path']).toList();
    expect(paths, ['Projects/Alpha']);
  });

  test('empty vault returns an empty folder list', () async {
    final storage = Storage(contentDir: Directory('${tmp.path}/content'));
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: MetaIndex(), storage: storage),
    );
    final body = await res.json() as Map<String, dynamic>;
    expect(body['folders'], isEmpty);
  });

  test('lists an explicitly created empty folder with a zero count', () async {
    final storage = Storage(contentDir: Directory('${tmp.path}/content'));
    await storage.createFolder('Ideas');
    final index = MetaIndex();
    await index.scan(storage);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
    );
    final body = await res.json() as Map<String, dynamic>;
    expect(body['folders'], [
      {'path': 'Ideas', 'note_count': 0, 'file_count': 0},
    ]);
  });

  test('a folder holding only a file appears with a file_count', () async {
    final storage = Storage(contentDir: Directory('${tmp.path}/content'));
    Directory('${tmp.path}/content/Attachments').createSync(recursive: true);
    File(
      '${tmp.path}/content/Attachments/diagram.png',
    ).writeAsBytesSync([1, 2, 3]);
    final index = MetaIndex();
    await index.scan(storage);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
    );
    final body = await res.json() as Map<String, dynamic>;
    expect(body['folders'], [
      {'path': 'Attachments', 'note_count': 0, 'file_count': 1},
    ]);
  });

  test(
    'a folder with a note, a marker, and a file reports both counts',
    () async {
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      await storage.createFolder('Ideas');
      File(
        '${tmp.path}/content/Ideas/diagram.png',
      ).writeAsBytesSync([1, 2, 3]);
      await storage.create(title: 'A', content: '', path: 'Ideas');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
      );
      final body = await res.json() as Map<String, dynamic>;
      expect(body['folders'], [
        {'path': 'Ideas', 'note_count': 1, 'file_count': 1},
      ]);
    },
  );

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.delete, metaIndex: MetaIndex()),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });

  group('POST /notes/tree', () {
    test('creates a new empty folder and returns 201', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Ideas'},
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'path': 'Ideas', 'note_count': 0});
      expect(
        File('${tmp.path}/content/Ideas/$kFolderMarkerFilename').existsSync(),
        isTrue,
      );
    });

    test('a subsequent GET lists the newly created folder', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();
      await index.scan(storage);
      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Ideas'},
        ),
      );

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
      );
      final body = await res.json() as Map<String, dynamic>;
      expect(body['folders'], [
        {'path': 'Ideas', 'note_count': 0, 'file_count': 0},
      ]);
    });

    test('creates missing intermediate folders for a nested path', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Projects/Gamma/Sub'},
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'path': 'Projects/Gamma/Sub', 'note_count': 0});
    });

    test(
        'a path that already has notes returns 200 with its count and no '
        'marker', () async {
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      await storage.create(title: 'A', content: '', path: 'Projects/Alpha');
      await storage.create(title: 'B', content: '', path: 'Projects/Alpha');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Projects/Alpha'},
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'path': 'Projects/Alpha', 'note_count': 2});
      expect(
        File(
          '${tmp.path}/content/Projects/Alpha/$kFolderMarkerFilename',
        ).existsSync(),
        isFalse,
      );
    });

    test(
        're-posting to a note-backed folder does not make it linger after '
        'its notes are removed', () async {
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final note = await storage.create(
        title: 'A',
        content: '',
        path: 'Projects/Alpha',
      );
      final index = MetaIndex();
      await index.scan(storage);

      // Re-creating an already note-backed folder (e.g. the "New folder"
      // prompt pre-filled with the current folder, confirmed unedited)
      // must not register it as a marker-tracked empty folder — no
      // marker was written to disk, so nothing should keep it listed
      // once its real notes are gone.
      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Projects/Alpha'},
        ),
      );
      await storage.delete(note.id);
      index.remove(note.id);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, metaIndex: index, storage: storage),
      );
      final body = await res.json() as Map<String, dynamic>;
      expect(body['folders'], isEmpty);
    });

    test(
        'a path that already has a marker-only folder returns 200, no '
        'duplicate marker or error', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      await storage.createFolder('Ideas');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Ideas'},
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'path': 'Ideas', 'note_count': 0});
    });

    test('a case-only-different path resolves to the existing folder',
        () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      await storage.createFolder('Ideas');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'ideas'},
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'path': 'Ideas', 'note_count': 0});
    });

    test('an empty path is rejected with 400', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': ''},
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a malformed JSON body is rejected with 400', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          malformedJson: true,
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('an invalid path segment is rejected with 400', () async {
      final storage = Storage(contentDir: Directory('${tmp.path}/content'));
      final index = MetaIndex();

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          metaIndex: index,
          storage: storage,
          jsonBody: {'path': 'Projects/../etc'},
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });
  });
}
