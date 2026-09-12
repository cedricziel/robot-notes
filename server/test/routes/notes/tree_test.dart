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
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
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

    final res =
        await route.onRequest(_ctx(method: HttpMethod.get, metaIndex: index));

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final folders = (body['folders'] as List).cast<Map<String, dynamic>>();
    expect(folders, [
      {'path': '', 'note_count': 2},
      {'path': 'Projects/Alpha', 'note_count': 1},
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

    final res =
        await route.onRequest(_ctx(method: HttpMethod.get, metaIndex: index));
    final body = await res.json() as Map<String, dynamic>;
    final paths =
        (body['folders'] as List).map((f) => (f as Map)['path']).toList();
    expect(paths, ['Projects/Alpha']);
  });

  test('empty vault returns an empty folder list', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: MetaIndex()),
    );
    final body = await res.json() as Map<String, dynamic>;
    expect(body['folders'], isEmpty);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, metaIndex: MetaIndex()),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
