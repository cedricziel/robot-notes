import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../routes/notes/[id].dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required Storage storage,
  required MetaIndex metaIndex,
  required LockManager lockManager,
  Actor actor = const Actor('tester'),
  Map<String, String> headers = const {},
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x'));
  when(() => req.headers).thenReturn(headers);
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
  when(() => ctx.read<LockManager>()).thenReturn(lockManager);
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-id-route-test-');
}

Storage _storage(Directory tmp) {
  var c = 0;
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
  late Storage storage;
  late MetaIndex index;
  late LockManager lockManager;

  setUp(() {
    tmp = _tempDir();
    storage = _storage(tmp);
    index = MetaIndex();
    lockManager = LockManager(
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
  });

  tearDown(() async {
    await lockManager.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GET /notes/{id}', () {
    test('returns 200 with the full record', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['id'], note.id);
      expect(body['title'], 't');
      expect(body['content'], 'c');
      expect(body['version'], 1);
      expect(body['lock'], isNull);
    });

    test('returns 404 not_found for unknown id', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'not_found');
    });

    test('includes lock state when the note is locked', () async {
      final note = await storage.create(title: 't', content: 'c');
      await lockManager.acquire(noteId: note.id, actor: 'alice');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        note.id,
      );
      final body = await res.json() as Map<String, dynamic>;
      final lock = body['lock'] as Map<String, dynamic>;
      expect(lock['holder'], 'alice');
      expect(lock['expires_at'], isA<String>());
    });
  });

  group('PUT /notes/{id}', () {
    test('without If-Match returns 428 precondition_required', () async {
      final note = await storage.create(title: 't', content: 'c');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          body: {'title': 'new', 'content': ''},
        ),
        note.id,
      );
      expect(res.statusCode, 428);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'precondition_required');
    });

    test('with non-numeric If-Match returns 400 bad_request', () async {
      final note = await storage.create(title: 't', content: 'c');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          headers: {'if-match': 'banana'},
          body: {'title': 'x', 'content': ''},
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('with stale If-Match returns 409 with current state', () async {
      final note = await storage.create(title: 't', content: 'c');
      await storage.update(
        id: note.id,
        title: 'updated',
        content: 'updated',
        ifMatch: 1,
      );
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          headers: {'if-match': '1'},
          body: {'title': 'mine', 'content': ''},
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'version_conflict');
      final current = body['current'] as Map<String, dynamic>;
      expect(current['version'], 2);
      expect(current['title'], 'updated');
    });

    test('while locked by another actor returns 423 locked', () async {
      final note = await storage.create(title: 't', content: 'c');
      await lockManager.acquire(noteId: note.id, actor: 'alice');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          actor: const Actor('bob'),
          headers: {'if-match': '1'},
          body: {'title': 'bob-edit', 'content': ''},
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'locked');
      final lock = body['lock'] as Map<String, dynamic>;
      expect(lock['holder'], 'alice');
    });

    test('by lock holder with matching If-Match returns 200 and bumps version',
        () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());
      await lockManager.acquire(noteId: note.id, actor: 'alice');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          actor: const Actor('alice'),
          headers: {'if-match': '1'},
          body: {'title': 'alice-edit', 'content': 'fresh'},
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['version'], 2);
      expect(body['title'], 'alice-edit');
      expect(body['content'], 'fresh');
      expect(index.get(note.id)?.version, 2);
      expect(index.get(note.id)?.title, 'alice-edit');
    });

    test('on unknown id returns 404 not_found', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          headers: {'if-match': '1'},
          body: {'title': 'x', 'content': ''},
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'not_found');
    });
  });

  group('DELETE /notes/{id}', () {
    test('returns 204 and removes the file', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.delete,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.noContent);
      expect(index.get(note.id), isNull);
      final file = File('${tmp.path}/content/${note.id}.md');
      expect(file.existsSync(), isFalse);
    });

    test('while locked by another actor returns 423 locked', () async {
      final note = await storage.create(title: 't', content: 'c');
      await lockManager.acquire(noteId: note.id, actor: 'alice');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.delete,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          actor: const Actor('bob'),
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.locked);
    });

    test('on unknown id returns 404 not_found', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.delete,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'not_found');
    });
  });

  group('error envelopes are stable', () {
    test('every error response carries an "error" string code', () async {
      // 404
      final r404 = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );
      final b404 = await r404.json() as Map<String, dynamic>;
      expect(b404['error'], isA<String>());
    });
  });

  group('disallowed methods', () {
    test('POST returns 405', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        'anything',
      );
      expect(res.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
