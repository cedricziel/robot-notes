import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:test/test.dart';

import '../../routes/notes/[id]/index.dart' as note_id_route;
import '../../routes/notes/index.dart' as notes_index_route;

/// Pins the **flat** `{"error": "<code>", ...siblings}` error body shape
/// that `server/API.md`'s "Error envelope" section documents, for the
/// codes issue #257 found the docs claiming a nested
/// `{"error": {"code", "message", "details"}}` envelope for instead. Each
/// route test file already exercises these codes individually; this file
/// exists so the *shape itself* — not just the code string — is asserted
/// in one place, and a future change that starts nesting `error` (or
/// renames a sibling key the docs promise) fails here instead of only
/// surfacing as a client-side parsing bug.
class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-error-shape-test-');

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
    broadcaster: Broadcaster(),
    lockManager: lockManager,
  );
}

RequestContext _notesCtx({
  required HttpMethod method,
  Storage? storage,
  MetaIndex? metaIndex,
  LockManager? lockManager,
  NoteWriteService? writes,
  Actor actor = const Actor('tester'),
  Map<String, String> headers = const {},
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes'));
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
  if (storage != null) when(() => ctx.read<Storage>()).thenReturn(storage);
  if (metaIndex != null) {
    when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  }
  if (lockManager != null) {
    when(() => ctx.read<LockManager>()).thenReturn(lockManager);
  }
  if (writes != null) {
    when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  }
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

void main() {
  group('flat error envelope (server/API.md "Error envelope")', () {
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

    test(
        'path_conflict: POST /notes on a title collision is exactly '
        '{"error": "path_conflict"} — no nested code/message/details object',
        () async {
      final writes = await _writeService(tmp, storage, index);
      await notes_index_route.onRequest(
        _notesCtx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Ideas'},
        ),
      );

      final res = await notes_index_route.onRequest(
        _notesCtx(
          method: HttpMethod.post,
          storage: storage,
          metaIndex: index,
          writes: writes,
          body: {'title': 'Ideas'},
        ),
      );

      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'error': 'path_conflict'});
      expect(body['error'], isA<String>());
    });

    test(
        'version_conflict: PUT /notes/{id} with a stale If-Match carries a '
        'flat "error" string plus a sibling "current" note object', () async {
      final note = await storage.create(title: 't', content: 'c');
      await storage.update(
        id: note.id,
        title: 'updated',
        content: 'updated',
        ifMatch: 1,
      );
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await note_id_route.onRequest(
        _notesCtx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          writes: writes,
          headers: {'if-match': '1'},
          body: {'title': 'mine', 'content': ''},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      // Flat top level: "error" and "current" only, "error" a bare string
      // — never {"error": {"code": "version_conflict", ...}}.
      expect(body.keys.toSet(), {'error', 'current'});
      expect(body['error'], 'version_conflict');
      final current = body['current'] as Map<String, dynamic>;
      expect(current.keys.toSet(), {
        'id',
        'title',
        'path',
        'content',
        'version',
        'created_at',
        'updated_at',
        'tags',
      });
      expect(current['version'], 2);
      expect(current['title'], 'updated');
    });

    test(
        'locked: PUT /notes/{id} held by another actor carries a flat '
        '"error" string plus a sibling "lock" object', () async {
      final note = await storage.create(title: 't', content: 'c');
      index.upsert(note.toSummary());
      await lockManager.acquire(noteId: note.id, actor: 'alice');
      final writes = await _writeService(
        tmp,
        storage,
        index,
        lockManager: lockManager,
      );

      final res = await note_id_route.onRequest(
        _notesCtx(
          method: HttpMethod.put,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
          writes: writes,
          actor: const Actor('bob'),
          headers: {'if-match': '1'},
          body: {'title': 'bob-edit', 'content': ''},
        ),
        note.id,
      );

      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body.keys.toSet(), {'error', 'lock'});
      expect(body['error'], 'locked');
      final lock = body['lock'] as Map<String, dynamic>;
      expect(lock.keys.toSet(), {'holder', 'expires_at'});
      expect(lock['holder'], 'alice');
    });

    test(
        'not_found: GET /notes/{id} for an unknown id is exactly '
        '{"error": "not_found"} — no nested code/message/details object',
        () async {
      final res = await note_id_route.onRequest(
        _notesCtx(
          method: HttpMethod.get,
          storage: storage,
          metaIndex: index,
          lockManager: lockManager,
        ),
        '01UNKNOWNXXXXXXXXXXXXXXXXX',
      );

      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'error': 'not_found'});
      expect(body['error'], isA<String>());
    });
  });

  group('flat error envelope: bearerAuth middleware', () {
    const configuredKey = 'rn_test_key';

    Config config() => const Config(
          apiKey: configuredKey,
          dataDir: '/tmp',
          port: 8080,
          lockTtlSeconds: 60,
          publicUrl: 'http://localhost',
        );

    RequestContext ctx({Map<String, String> headers = const {}}) {
      final ctx = _MockRequestContext();
      final req = _MockRequest();
      when(() => req.method).thenReturn(HttpMethod.get);
      when(() => req.uri).thenReturn(Uri.parse('http://localhost/notes'));
      when(() => req.headers).thenReturn(headers);
      when(() => ctx.request).thenReturn(req);
      when(() => ctx.read<Config>()).thenReturn(config());
      when(() => ctx.read<TokenStore>()).thenReturn(
        TokenStore(
          dir: Directory(
            '${Directory.systemTemp.path}/robot-notes-error-shape-auth-unused',
          ),
        ),
      );
      // `provide<T>()` must return a fresh context whose `read<T>()` yields
      // the supplied value — mirrors the stub in auth_middleware_test.dart.
      when(() => ctx.provide<RestPrincipal>(any())).thenAnswer((invocation) {
        final create =
            invocation.positionalArguments.first as RestPrincipal Function();
        final value = create();
        when(() => ctx.read<RestPrincipal>()).thenReturn(value);
        return ctx;
      });
      return ctx;
    }

    test(
        'unauthorized: a missing bearer credential on GET /notes is exactly '
        '{"error": "unauthorized"} — no nested code/message/details object',
        () async {
      final mw = bearerAuth(configuredKey: configuredKey);
      final wrapped = mw((_) async => Response(body: 'ok'));
      final res = await wrapped(ctx());

      expect(res.statusCode, HttpStatus.unauthorized);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {'error': 'unauthorized'});
      expect(body['error'], isA<String>());
    });
  });
}
