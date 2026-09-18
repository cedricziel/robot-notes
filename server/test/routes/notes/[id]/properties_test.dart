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

import '../../../../routes/notes/[id]/properties.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

class _CapturingBroadcaster implements Broadcaster {
  final List<ChangedEvent> changed = [];

  @override
  void emitChanged(ChangedEvent event) => changed.add(event);

  @override
  int get connectionCount => 0;

  @override
  bool isRegistered(String connectionId) => false;

  @override
  Stream<WsMessage> register(String connectionId) => throw UnimplementedError();

  @override
  void subscribe(String connectionId, String noteId) =>
      throw UnimplementedError();

  @override
  void subscribeWildcard(String connectionId) => throw UnimplementedError();

  @override
  void unsubscribe(String connectionId, String noteId) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect(String connectionId) async =>
      throw UnimplementedError();

  @override
  void emitLock(LockEvent event) => throw UnimplementedError();

  @override
  void emitPresence(PresenceEvent event) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

RequestContext _ctx({
  required HttpMethod method,
  required NoteWriteService writes,
  Actor actor = const Actor('bob'),
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x/properties'));
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

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-properties-route-test-');

void main() {
  late Directory tmp;
  late Storage storage;
  late MetaIndex meta;
  late LockManager lockManager;
  late _CapturingBroadcaster broadcaster;
  late NoteWriteService writes;

  setUp(() async {
    tmp = _tempDir();
    storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    meta = MetaIndex();
    lockManager = LockManager(
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    broadcaster = _CapturingBroadcaster();
    final search = await SearchIndex.open(
      dbFile: File('${tmp.path}/search.db'),
      storage: storage,
    );
    addTearDown(search.close);
    writes = NoteWriteService(
      storage: storage,
      metaIndex: meta,
      searchIndex: search,
      broadcaster: broadcaster,
      lockManager: lockManager,
    );
  });

  tearDown(() async {
    await lockManager.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('returns 200 with the updated note', () async {
    final note = await storage.create(
      title: 't',
      content: 'Hello',
      properties: {'status': 'Idea', 'mood': 'great'},
    );
    meta.upsert(note.toSummary());

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        body: {
          'set': {'status': 'Active'},
          'unset': ['mood'],
        },
      ),
      note.id,
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['properties'], {'status': 'Active'});
    expect(body['content'], 'Hello');
    expect(body['version'], 2);
  });

  test('empty patch returns 400 validation_failed', () async {
    final note = await storage.create(title: 't', content: 'c');
    meta.upsert(note.toSummary());

    final res = await route.onRequest(
      _ctx(method: HttpMethod.patch, writes: writes, body: <String, Object?>{}),
      note.id,
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'validation_failed');
  });

  test('reserved key returns 400 validation_failed', () async {
    final note = await storage.create(title: 't', content: 'c');
    meta.upsert(note.toSummary());

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        body: {
          'set': {'title': 'X'},
        },
      ),
      note.id,
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'validation_failed');
  });

  test('unknown id returns 404 not_found', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        body: {
          'set': {'status': 'Active'},
        },
      ),
      '01UNKNOWNXXXXXXXXXXXXXXXXX',
    );

    expect(res.statusCode, HttpStatus.notFound);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'not_found');
  });

  test('needs no If-Match header', () async {
    final note = await storage.create(title: 't', content: 'c');
    meta.upsert(note.toSummary());

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        body: {
          'set': {'status': 'Active'},
        },
      ),
      note.id,
    );

    expect(res.statusCode, HttpStatus.ok);
  });

  test('ignores another actor\'s editor lock', () async {
    final note = await storage.create(title: 't', content: 'c');
    meta.upsert(note.toSummary());
    await lockManager.acquire(noteId: note.id, actor: 'alice');

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        actor: const Actor('bob'),
        body: {
          'set': {'status': 'Active'},
        },
      ),
      note.id,
    );

    expect(res.statusCode, HttpStatus.ok);
  });

  test('broadcasts a changed:updated event', () async {
    final note = await storage.create(title: 't', content: 'c');
    meta.upsert(note.toSummary());

    await route.onRequest(
      _ctx(
        method: HttpMethod.patch,
        writes: writes,
        actor: const Actor('bob'),
        body: {
          'set': {'status': 'Active'},
        },
      ),
      note.id,
    );

    expect(broadcaster.changed, hasLength(1));
    expect(broadcaster.changed.single.by, 'bob');
    expect(broadcaster.changed.single.action, ChangeAction.updated);
  });
}
