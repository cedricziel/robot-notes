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

import '../../../../routes/databases/[id]/rows.dart' as route;

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
  when(() => req.uri).thenReturn(Uri.parse('/databases/x/rows'));
  if (body != null) {
    final captured = body;
    when(req.json).thenAnswer((_) => Future<Object>.value(captured));
  } else {
    when(req.json).thenAnswer(
      (_) => Future<Object>.error(const FormatException('no body')),
    );
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<NoteWriteService>()).thenReturn(writes);
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-databases-rows-test-');

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

  test('lands in the source folder', () async {
    final db = await makeDb();
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        writes: writes,
        body: {
          'title': 'Rewrite',
          'properties': {'status': 'Idea'},
        },
      ),
      db.id,
    );

    expect(res.statusCode, HttpStatus.created);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['path'], 'Projects');
    expect(
        File('${tmp.path}/content/Projects/Rewrite.md').existsSync(), isTrue);
    expect(body['properties'], {'status': 'Idea'});
  });

  test('a tag source row gets the source tag', () async {
    final db = await writes.createDatabase(
      title: 'Tagged',
      actor: 'a',
      source: const DatabaseSource.tag('project'),
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        writes: writes,
        body: {'title': 'Anywhere'},
      ),
      db.id,
    );

    expect(res.statusCode, HttpStatus.created);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['tags'], contains('project'));
  });

  test('a path outside the source is rejected and writes nothing', () async {
    final db = await makeDb();

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        writes: writes,
        body: {'title': 'Escapee', 'path': 'Archive'},
      ),
      db.id,
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'validation_failed');
    expect(
      File('${tmp.path}/content/Archive/Escapee.md').existsSync(),
      isFalse,
    );
  });

  test('a validation failure writes nothing', () async {
    final db = await makeDb();

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        writes: writes,
        body: {
          'title': 'Bad',
          'properties': {'status': 'Blocked'},
        },
      ),
      db.id,
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['error'], 'validation_failed');
    expect(
      File('${tmp.path}/content/Projects/Bad.md').existsSync(),
      isFalse,
    );
  });

  test('unknown database id returns 404 not_found', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, writes: writes, body: {'title': 'x'}),
      '01UNKNOWNXXXXXXXXXXXXXXXXX',
    );
    expect(res.statusCode, HttpStatus.notFound);
  });
}
