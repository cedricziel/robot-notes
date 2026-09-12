import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../../routes/notes/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required Storage storage,
  required MetaIndex metaIndex,
  NoteWriteService? writes,
  Broadcaster? broadcaster,
  Actor? actor,
  Uri? uri,
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(uri ?? Uri.parse('/notes'));
  if (body != null) {
    final captured = body;
    when(req.json).thenAnswer(
      // ignore: unnecessary_lambdas
      (_) => Future<Object>.value(captured),
    );
  } else {
    when(req.json).thenAnswer(
      // ignore: unnecessary_lambdas
      (_) => Future<Object>.error(const FormatException('no body provided')),
    );
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Storage>()).thenReturn(storage);
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  when(() => ctx.read<Broadcaster>()).thenReturn(broadcaster ?? Broadcaster());
  if (writes != null) {
    when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  }
  when(() => ctx.read<Actor>()).thenReturn(actor ?? Actor.unknown);
  return ctx;
}

Future<NoteWriteService> _writeService(
  Directory tmp,
  Storage storage,
  MetaIndex metaIndex, {
  Broadcaster? broadcaster,
}) async {
  final search = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
  );
  addTearDown(search.close);
  return NoteWriteService(
    storage: storage,
    metaIndex: metaIndex,
    searchIndex: search,
    broadcaster: broadcaster ?? Broadcaster(),
  );
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-notes-route-test-');
}

Storage _storage(Directory tmp, {int counter = 0}) {
  var c = counter;
  return Storage(
    contentDir: Directory('${tmp.path}/content'),
    clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5F${String.fromCharCode(
      0x41 + c++,
    )}1',
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

  group('GET /notes', () {
    test('returns paginated metadata with default limit 50', () async {
      final storage = _storage(tmp);
      for (var i = 0; i < 3; i++) {
        await storage.create(title: 'note-$i', content: 'body-$i');
      }
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage, metaIndex: index),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['limit'], 50);
      expect(body['items'], hasLength(3));
      expect(body['next_cursor'], isNull);
    });

    test('list items omit the content field', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'with-body', content: 'should not leak');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage, metaIndex: index),
      );

      final body = await res.json() as Map<String, dynamic>;
      final first = (body['items'] as List).first as Map<String, dynamic>;
      expect(first.containsKey('content'), isFalse);
      expect(first['title'], 'with-body');
    });

    test('list items include a computed excerpt and sorted tags', () async {
      final storage = _storage(tmp);
      await storage.create(
        title: 'with-tags',
        content: '# Heading\nSome body text here. #zebra #apple',
      );
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage, metaIndex: index),
      );

      final body = await res.json() as Map<String, dynamic>;
      final first = (body['items'] as List).first as Map<String, dynamic>;
      expect(first['excerpt'], 'Heading Some body text here.');
      expect(first['tags'], ['apple', 'zebra']);
    });

    test('clamps limit to kMaxPageSize when caller asks for more', () async {
      final storage = _storage(tmp);
      for (var i = 0; i < 5; i++) {
        await storage.create(title: 'n-$i', content: '');
      }
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?limit=${kMaxPageSize + 50}'),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['limit'], kMaxPageSize);
    });

    test('honors limit=200 verbatim (boundary value)', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?limit=200'),
        ),
      );
      final body = await res.json() as Map<String, dynamic>;
      expect(body['limit'], 200);
    });

    test('cursor pagination walks the full index then ends with null',
        () async {
      final storage = _storage(tmp);
      for (var i = 0; i < 3; i++) {
        await storage.create(title: 't$i', content: '');
      }
      final index = MetaIndex();
      await index.scan(storage);

      // Page 1
      final res1 = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?limit=2'),
        ),
      );
      final body1 = await res1.json() as Map<String, dynamic>;
      expect(body1['items'] as List, hasLength(2));
      expect(body1['next_cursor'], isNotNull);

      // Page 2 (final)
      final res2 = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?limit=2&after=${body1['next_cursor']}'),
        ),
      );
      final body2 = await res2.json() as Map<String, dynamic>;
      expect(body2['items'] as List, hasLength(1));
      expect(body2['next_cursor'], isNull);
    });

    test('limit=0 returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?limit=0'),
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('sort=updated_desc returns newest-updated notes first', () async {
      final contentDir = Directory('${tmp.path}/content');
      final early = Storage(
        contentDir: contentDir,
        clock: FixedClock.fixed(DateTime.utc(2026)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5FA1',
      );
      final late = Storage(
        contentDir: contentDir,
        clock: FixedClock.fixed(DateTime.utc(2026, 1, 2)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5FB1',
      );
      // 'b' has a later updated_at, so it should sort first.
      final a = await early.create(title: 'a', content: '');
      final b = await late.create(title: 'b', content: '');
      final storage = Storage(contentDir: contentDir);
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?sort=updated_desc'),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      final ids = (body['items'] as List)
          .map((e) => (e as Map<String, dynamic>)['id'])
          .toList();
      expect(ids.indexOf(b.id), lessThan(ids.indexOf(a.id)));
    });

    test('sort=updated_desc paginates with an opaque cursor', () async {
      final storage = _storage(tmp);
      for (var i = 0; i < 3; i++) {
        await storage.create(title: 't$i', content: '');
      }
      final index = MetaIndex();
      await index.scan(storage);

      final res1 = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?sort=updated_desc&limit=2'),
        ),
      );
      final body1 = await res1.json() as Map<String, dynamic>;
      expect(body1['items'] as List, hasLength(2));
      expect(body1['next_cursor'], isNotNull);

      final res2 = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse(
            '/notes?sort=updated_desc&limit=2&after=${body1['next_cursor']}',
          ),
        ),
      );
      final body2 = await res2.json() as Map<String, dynamic>;
      expect(body2['items'] as List, hasLength(1));
      expect(body2['next_cursor'], isNull);
    });

    test('unknown sort value returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?sort=bogus'),
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('malformed cursor for sort=updated_desc returns 400 bad_request',
        () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?sort=updated_desc&after=not-a-cursor'),
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('path filter returns only notes under that folder', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: '', path: 'Projects/Alpha');
      await storage.create(title: 'B', content: '', path: 'Projects/Beta');
      await storage.create(title: 'C', content: '');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?path=Projects/Alpha'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = body['items'] as List;
      expect(items, hasLength(1));
      expect((items.single as Map)['title'], 'A');
      expect((items.single as Map)['path'], 'Projects/Alpha');
    });

    test('path filter composes with sort=updated_desc', () async {
      final contentDir = Directory('${tmp.path}/content');
      final early = Storage(
        contentDir: contentDir,
        clock: FixedClock.fixed(DateTime.utc(2026)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5FA1',
      );
      final late = Storage(
        contentDir: contentDir,
        clock: FixedClock.fixed(DateTime.utc(2026, 1, 2)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5FB1',
      );
      final root = Storage(
        contentDir: contentDir,
        clock: FixedClock.fixed(DateTime.utc(2026, 1, 3)),
        idGenerator: () => '01ARZ3NDEKTSV4RRFFQ69G5FC1',
      );
      await early.create(title: 'old-in-folder', content: '', path: 'Folder');
      final newInFolder = await late.create(
        title: 'new-in-folder',
        content: '',
        path: 'Folder',
      );
      // A more-recently-updated note outside the folder must not appear.
      await root.create(title: 'newest-at-root', content: '');

      final storage = Storage(contentDir: contentDir);
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?path=Folder&sort=updated_desc'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final ids = (body['items'] as List)
          .map((e) => (e as Map<String, dynamic>)['id'])
          .toList();
      expect(ids.first, newInFolder.id);
      expect(ids, hasLength(2));
    });

    test('tag filter returns only notes carrying that tag', () async {
      final storage = _storage(tmp);
      await storage.create(title: 'A', content: '#urgent');
      await storage.create(title: 'B', content: '#urgent');
      await storage.create(title: 'C', content: 'no tags here');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?tag=urgent'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      expect(items.map((e) => e['title']), containsAll(['A', 'B']));
    });

    test('tag filter composes with path filter', () async {
      final storage = _storage(tmp);
      await storage.create(
        title: 'A',
        content: '#urgent',
        path: 'Projects/Alpha',
      );
      await storage.create(title: 'B', content: '#urgent');
      final index = MetaIndex();
      await index.scan(storage);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          uri: Uri.parse('/notes?tag=urgent&path=Projects/Alpha'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(1));
      expect(items.single['title'], 'A');
    });
  });

  group('POST /notes', () {
    test('returns 201 with full record at version 1', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final writes = await _writeService(tmp, storage, index);
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'hello', 'content': 'world'},
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['title'], 'hello');
      expect(body['content'], 'world');
      expect(body['version'], 1);
      expect(body['id'], isNotEmpty);
      expect(body['created_at'], isNotEmpty);
      expect(body['updated_at'], isNotEmpty);
      expect(index.length, 1);
    });

    test('persists into the meta index so the next list sees the row',
        () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final writes = await _writeService(tmp, storage, index);
      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'new', 'content': ''},
        ),
      );
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage, metaIndex: index),
      );
      final body = await res.json() as Map<String, dynamic>;
      final items = body['items'] as List;
      expect(items, hasLength(1));
      expect((items.first as Map)['title'], 'new');
    });

    test('missing title returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          body: {'content': 'no title here'},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('empty title returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          body: {'title': '   ', 'content': ''},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('non-object body returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          body: 'just a string',
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('non-string content returns 400 bad_request', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          body: {'title': 'ok', 'content': 12345},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('creates the note under the given path', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final writes = await _writeService(tmp, storage, index);
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Meeting', 'path': 'Projects/Alpha'},
        ),
      );
      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['path'], 'Projects/Alpha');
    });

    test('colliding title returns 409 path_conflict', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final writes = await _writeService(tmp, storage, index);
      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Ideas'},
        ),
      );
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Ideas'},
        ),
      );
      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'path_conflict');
    });

    test('a path-traversal attempt is rejected, not written to disk', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final writes = await _writeService(tmp, storage, index);
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Escape', 'path': '../../../tmp/escaped'},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
      final contentDir = Directory('${tmp.path}/content');
      expect(
        contentDir.existsSync()
            ? contentDir.listSync(recursive: true)
            : const <FileSystemEntity>[],
        isEmpty,
        reason: 'the traversal must not write any file anywhere',
      );
    });
  });

  group('disallowed methods', () {
    test('PUT /notes returns 405 method_not_allowed', () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final res = await route.onRequest(
        _ctx(method: HttpMethod.put, storage: storage, metaIndex: index),
      );
      expect(res.statusCode, HttpStatus.methodNotAllowed);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'method_not_allowed');
    });
  });

  group('changed event', () {
    test('successful POST emits a changed:created event without content',
        () async {
      final storage = _storage(tmp);
      final index = MetaIndex();
      final broadcaster = Broadcaster();
      addTearDown(broadcaster.close);
      final writes = await _writeService(
        tmp,
        storage,
        index,
        broadcaster: broadcaster,
      );

      final received = <WsMessage>[];
      broadcaster
        ..register('listener').listen(received.add)
        ..subscribeWildcard('listener');

      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          broadcaster: broadcaster,
          writes: writes,
          actor: const Actor('alice'),
          body: {'title': 'hello', 'content': 'world'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final ev = received.single as ChangedEvent;
      expect(ev.action, ChangeAction.created);
      expect(ev.version, 1);
      expect(ev.by, 'alice');
      expect(ev.toJson().containsKey('content'), isFalse);
    });
  });
}
