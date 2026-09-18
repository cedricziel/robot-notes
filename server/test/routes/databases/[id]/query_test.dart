import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../../../routes/databases/[id]/query.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required DatabaseRegistry registry,
  required SearchIndex searchIndex,
  required MetaIndex metaIndex,
  Object? body,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/databases/x/query'));
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
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-databases-query-test-');

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
        views: const [
          ViewDefinition(
            name: 'Active',
            type: ViewType.table,
            filter: Condition(
              property: 'status',
              op: FilterOp.neq,
              value: 'Done',
            ),
          ),
          ViewDefinition(
            name: 'Kanban',
            type: ViewType.board,
            groupBy: 'status',
          ),
        ],
      );

  test('queries a saved view', () async {
    final db = await makeDb();
    await writes.createRow(
      databaseId: db.id,
      title: 'A',
      actor: 'a',
      properties: {'status': 'Idea'},
    );
    await writes.createRow(
      databaseId: db.id,
      title: 'B',
      actor: 'a',
      properties: {'status': 'Done'},
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {'view': 'Active'},
      ),
      db.id,
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final items = body['items'] as List;
    expect(items, hasLength(1));
    expect((items.single as Map)['title'], 'A');
  });

  test('a request filter overrides the view filter', () async {
    final db = await makeDb();
    await writes.createRow(
      databaseId: db.id,
      title: 'A',
      actor: 'a',
      properties: {'status': 'Idea'},
    );
    await writes.createRow(
      databaseId: db.id,
      title: 'B',
      actor: 'a',
      properties: {'status': 'Done'},
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {
          'view': 'Active',
          'filter': {'property': 'status', 'op': 'eq', 'value': 'Done'},
        },
      ),
      db.id,
    );

    final body = await res.json() as Map<String, dynamic>;
    final items = body['items'] as List;
    expect(items, hasLength(1));
    expect((items.single as Map)['title'], 'B');
  });

  test('grouped query returns group counts', () async {
    final db = await makeDb();
    await writes.createRow(
      databaseId: db.id,
      title: 'A',
      actor: 'a',
      properties: {'status': 'Idea'},
    );
    await writes.createRow(
      databaseId: db.id,
      title: 'B',
      actor: 'a',
      properties: {'status': 'Idea'},
    );
    await writes.createRow(databaseId: db.id, title: 'C', actor: 'a');

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {'view': 'Kanban'},
      ),
      db.id,
    );

    final body = await res.json() as Map<String, dynamic>;
    expect(body['groups'], [
      {'value': 'Idea', 'count': 2},
      {'value': 'Active', 'count': 0},
      {'value': 'Done', 'count': 0},
      {'value': null, 'count': 1},
    ]);
  });

  test('pagination returns limited pages with a next_cursor', () async {
    final db = await makeDb();
    for (var i = 0; i < 5; i++) {
      await writes.createRow(databaseId: db.id, title: 'Row $i', actor: 'a');
    }

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {'limit': 2},
      ),
      db.id,
    );
    final body = await res.json() as Map<String, dynamic>;
    expect((body['items'] as List), hasLength(2));
    expect(body['next_cursor'], isNotNull);
  });

  test('a tag source database matches tagged notes regardless of folder',
      () async {
    final db = await writes.createDatabase(
      title: 'Tagged',
      actor: 'a',
      source: const DatabaseSource.tag('project'),
    );
    await writes.create(
      title: 'Anywhere',
      content: 'body #project',
      actor: 'a',
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: <String, Object?>{},
      ),
      db.id,
    );
    final body = await res.json() as Map<String, dynamic>;
    expect((body['items'] as List), hasLength(1));
  });

  test('unknown view returns 400 validation_failed', () async {
    final db = await makeDb();
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {'view': 'Nope'},
      ),
      db.id,
    );
    expect(res.statusCode, HttpStatus.badRequest);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'validation_failed');
  });

  test('limit above 200 is rejected', () async {
    final db = await makeDb();
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: {'limit': 201},
      ),
      db.id,
    );
    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('items never include content', () async {
    final db = await makeDb();
    await writes.createRow(
      databaseId: db.id,
      title: 'A',
      actor: 'a',
      content: 'secret body',
      properties: {'status': 'Idea'},
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: <String, Object?>{},
      ),
      db.id,
    );
    final body = await res.json() as Map<String, dynamic>;
    final item = (body['items'] as List).single as Map;
    expect(item.containsKey('content'), isFalse);
  });

  test('unknown database id returns 404 not_found', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        registry: registry,
        searchIndex: search,
        metaIndex: meta,
        body: <String, Object?>{},
      ),
      '01UNKNOWNXXXXXXXXXXXXXXXXX',
    );
    expect(res.statusCode, HttpStatus.notFound);
  });
}
