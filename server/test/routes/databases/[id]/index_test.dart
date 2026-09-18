import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../../../routes/databases/[id]/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required DatabaseRegistry registry,
  NoteWriteService? writes,
  Actor actor = const Actor('tester'),
  Map<String, String> headers = const {},
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/databases/x'));
  when(() => req.headers).thenReturn(headers);
  if (body != null) {
    final captured = body;
    when(req.json).thenAnswer((_) => Future<Object>.value(captured));
  } else {
    when(req.json).thenAnswer(
      (_) => Future<Object>.error(const FormatException('no body')),
    );
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<DatabaseRegistry>()).thenReturn(registry);
  if (writes != null) {
    when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  }
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

Directory _tempDir() => Directory.systemTemp
    .createTempSync('robot-notes-databases-id-route-test-');

void main() {
  late Directory tmp;
  late Storage storage;
  late MetaIndex meta;
  late SearchIndex search;
  late DatabaseRegistry registry;
  late NoteWriteService writes;

  setUp(() async {
    tmp = _tempDir();
    storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    meta = MetaIndex();
    search = await SearchIndex.open(
      dbFile: File('${tmp.path}/search.db'),
      storage: storage,
    );
    registry = DatabaseRegistry();
    writes = NoteWriteService(
      storage: storage,
      metaIndex: meta,
      searchIndex: search,
      broadcaster: Broadcaster(),
      registry: registry,
    );
  });

  tearDown(() {
    search.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<StoredNote> makeDb() => writes.createDatabase(
        title: 'Projects',
        actor: 'a',
        source: const DatabaseSource.folder('Projects'),
        path: 'Projects',
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['Idea', 'Active', 'Done'],
          ),
        },
        views: const [ViewDefinition(name: 'All', type: ViewType.table)],
      );

  group('GET /databases/{id}', () {
    test('returns the full definition', () async {
      final note = await makeDb();
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry),
        note.id,
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['title'], 'Projects');
      expect(body['properties'], isNotEmpty);
      expect(body['views'], isNotEmpty);
    });

    test('an ordinary note id returns 404 not_found', () async {
      final note = await storage.create(title: 'Not a db', content: '');
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry),
        note.id,
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'not_found');
    });
  });

  group('PUT /databases/{id}', () {
    test('without If-Match returns 428', () async {
      final note = await makeDb();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          registry: registry,
          writes: writes,
          body: <String, Object?>{},
        ),
        note.id,
      );
      expect(res.statusCode, 428);
    });

    test('with a stale If-Match returns 409 version_conflict', () async {
      final note = await makeDb();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          registry: registry,
          writes: writes,
          headers: {'if-match': '1'},
          body: {
            'properties': <String, Object?>{},
          },
        ),
        note.id,
      );
      // First update at version 1 succeeds; verify a second stale attempt
      // conflicts.
      expect(res.statusCode, HttpStatus.ok);
      final second = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          registry: registry,
          writes: writes,
          headers: {'if-match': '1'},
          body: {
            'properties': <String, Object?>{},
          },
        ),
        note.id,
      );
      expect(second.statusCode, HttpStatus.conflict);
      final body = await second.json() as Map<String, dynamic>;
      expect(body['error'], 'version_conflict');
    });

    test(
      'removing a property from the schema keeps row values on disk',
      () async {
        final note = await makeDb();
        final row = await writes.createRow(
          databaseId: note.id,
          title: 'Task A',
          actor: 'a',
          properties: {'status': 'Idea'},
        );

        final res = await route.onRequest(
          _ctx(
            method: HttpMethod.put,
            registry: registry,
            writes: writes,
            headers: {'if-match': '1'},
            body: {
              'properties': <String, Object?>{},
            },
          ),
          note.id,
        );
        expect(res.statusCode, HttpStatus.ok);
        final body = await res.json() as Map<String, dynamic>;
        expect(body['properties'], isEmpty);

        final rowOnDisk = await storage.read(row.id);
        expect(rowOnDisk.extra['status'], 'Idea');
      },
    );

    test('a body-only update preserves type/source/properties/views',
        () async {
      final note = await makeDb();
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          registry: registry,
          writes: writes,
          headers: {'if-match': '1'},
          body: {'content': 'hello'},
        ),
        note.id,
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['properties'], isNotEmpty);
      expect(body['views'], isNotEmpty);
    });

    test('after the definition is deleted returns 404', () async {
      final note = await makeDb();
      await writes.delete(id: note.id, actor: 'a');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry),
        note.id,
      );
      expect(res.statusCode, HttpStatus.notFound);
    });
  });
}
