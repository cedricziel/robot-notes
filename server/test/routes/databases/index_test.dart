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

import '../../../routes/databases/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required DatabaseRegistry registry,
  required SearchIndex searchIndex,
  NoteWriteService? writes,
  Actor actor = const Actor('tester'),
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/databases'));
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
  when(() => ctx.read<SearchIndex>()).thenReturn(searchIndex);
  if (writes != null) {
    when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  }
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-databases-route-test-');

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

  group('GET /databases', () {
    test('lists a registered database with row_count', () async {
      await writes.createDatabase(
        title: 'Projects',
        actor: 'a',
        source: const DatabaseSource.folder('Projects'),
        path: 'Projects',
      );
      await writes.create(
          title: 'Row 1', content: '', actor: 'a', path: 'Projects');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry, searchIndex: search),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      final items = body['items'] as List;
      expect(items, hasLength(1));
      final item = items.single as Map<String, dynamic>;
      expect(item['title'], 'Projects');
      expect(item['row_count'], 1);
    });

    test('empty registry returns empty items', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry, searchIndex: search),
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['items'], isEmpty);
    });
  });

  group('POST /databases', () {
    test('creates a database note and returns 201', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          registry: registry,
          searchIndex: search,
          writes: writes,
          body: {
            'title': 'Projects',
            'source': {'folder': 'Projects'},
            'properties': {
              'status': {
                'type': 'select',
                'options': ['Idea', 'Active', 'Done'],
              },
            },
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['title'], 'Projects');
      expect(File('${tmp.path}/content/Projects.md').existsSync(), isTrue);

      final list = await route.onRequest(
        _ctx(method: HttpMethod.get, registry: registry, searchIndex: search),
      );
      final items =
          (await list.json() as Map<String, dynamic>)['items'] as List;
      expect(items, hasLength(1));
    });

    test('reserved property key returns 400 validation_failed', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          registry: registry,
          searchIndex: search,
          writes: writes,
          body: {
            'title': 'Projects',
            'properties': {
              'version': {'type': 'text'},
            },
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'validation_failed');
    });

    test('board view without group_by returns 400 validation_failed', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          registry: registry,
          searchIndex: search,
          writes: writes,
          body: {
            'title': 'Projects',
            'properties': <String, Object?>{},
            'views': [
              {'name': 'Kanban', 'type': 'board'},
            ],
          },
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'validation_failed');
    });

    test('colliding path returns 409 path_conflict', () async {
      await storage.create(title: 'Projects', content: '');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          registry: registry,
          searchIndex: search,
          writes: writes,
          body: {
            'title': 'Projects',
            'properties': <String, Object?>{},
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      );
      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'path_conflict');
    });
  });
}
