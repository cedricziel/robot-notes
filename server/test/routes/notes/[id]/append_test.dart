import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/[id]/append.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required NoteWriteService writes,
  Actor actor = const Actor('tester'),
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x/append'));
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
  when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-append-route-test-');
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

Future<NoteWriteService> _writeService(
  Directory tmp,
  Storage storage,
  MetaIndex metaIndex, {
  LockManager? lockManager,
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
    lockManager: lockManager,
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

  group('POST /notes/{id}/append', () {
    test('appends on a new line and returns the updated note', () async {
      final note = await storage.create(title: 't', content: 'line one');
      index.upsert(note.toSummary());
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          actor: const Actor('alice'),
          body: {'content': 'line two'},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['id'], note.id);
      expect(body['content'], 'line one\nline two');
      expect(body['version'], 2);
      expect(index.get(note.id)?.version, 2);
    });

    test('appending to an empty note does not prepend a newline', () async {
      final note = await storage.create(title: 't', content: '');
      index.upsert(note.toSummary());
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          body: {'content': 'first line'},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['content'], 'first line');
    });

    test('missing content returns 400 validation_failed', () async {
      final note = await storage.create(title: 't', content: 'c');
      final writes = await _writeService(tmp, storage, index);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          body: <String, Object?>{},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'validation_failed');
    });

    test('empty content returns 400 validation_failed', () async {
      final note = await storage.create(title: 't', content: 'c');
      final writes = await _writeService(tmp, storage, index);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          body: {'content': '   '},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'validation_failed');
    });

    test('non-JSON body returns 400 bad_request', () async {
      final note = await storage.create(title: 't', content: 'c');
      final writes = await _writeService(tmp, storage, index);

      final res = await route.onRequest(
        _ctx(method: HttpMethod.post, writes: writes),
        note.id,
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('on unknown id returns 404 not_found', () async {
      final writes = await _writeService(tmp, storage, index);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          body: {'content': 'x'},
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );

      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'not_found');
    });

    test('while locked by another actor returns 423 locked', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());
      await lockManager.acquire(noteId: note.id, actor: 'alice');
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          actor: const Actor('bob'),
          body: {'content': 'x'},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'locked');
      final lock = body['lock'] as Map<String, dynamic>;
      expect(lock['holder'], 'alice');
      // The note is unchanged.
      expect((await storage.read(note.id)).content, 'c');
    });

    test('by the lock holder succeeds', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());
      await lockManager.acquire(noteId: note.id, actor: 'alice');
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          actor: const Actor('alice'),
          body: {'content': 'more'},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['content'], 'c\nmore');
    });

    test('two concurrent appends both land', () async {
      final note = await storage.create(title: 't', content: 'base');
      index.upsert(note.toSummary());
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final results = await Future.wait([
        route.onRequest(
          _ctx(
            method: HttpMethod.post,
            writes: writes,
            actor: const Actor('alice'),
            body: {'content': 'from-alice'},
          ),
          note.id,
        ),
        route.onRequest(
          _ctx(
            method: HttpMethod.post,
            writes: writes,
            actor: const Actor('bob'),
            body: {'content': 'from-bob'},
          ),
          note.id,
        ),
      ]);

      for (final res in results) {
        expect(res.statusCode, HttpStatus.ok);
      }

      final finalNote = await storage.read(note.id);
      expect(finalNote.version, 3);
      expect(finalNote.content, contains('from-alice'));
      expect(finalNote.content, contains('from-bob'));
      expect(finalNote.content, contains('base'));
    });

    test('emits a changed:updated event on success', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());
      final broadcaster = Broadcaster();
      addTearDown(broadcaster.close);
      final received = <WsMessage>[];
      broadcaster
        ..register('listener').listen(received.add)
        ..subscribeWildcard('listener');
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
        broadcaster: broadcaster,
      );

      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          writes: writes,
          actor: const Actor('alice'),
          body: {'content': 'more'},
        ),
        note.id,
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final ev = received.single as ChangedEvent;
      expect(ev.noteId, note.id);
      expect(ev.action, ChangeAction.updated);
      expect(ev.version, 2);
      expect(ev.by, 'alice');
    });
  });

  group('disallowed methods', () {
    test('GET returns 405 method_not_allowed', () async {
      final writes = await _writeService(tmp, storage, index);
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, writes: writes),
        'anything',
      );
      expect(res.statusCode, HttpStatus.methodNotAllowed);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'method_not_allowed');
    });
  });
}
