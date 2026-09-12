import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../routes/tags.dart' as route;

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
    Directory.systemTemp.createTempSync('robot-notes-tags-route-test-');

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('lists tags sorted by descending count', () async {
    final storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    await storage.create(title: 'A', content: '#urgent');
    await storage.create(title: 'B', content: '#urgent');
    await storage.create(title: 'C', content: '#urgent #later');
    final index = MetaIndex();
    await index.scan(storage);

    final res =
        await route.onRequest(_ctx(method: HttpMethod.get, metaIndex: index));

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items, [
      {'tag': 'urgent', 'count': 3},
      {'tag': 'later', 'count': 1},
    ]);
  });

  test('an empty vault returns an empty items list', () async {
    final index = MetaIndex();
    final res =
        await route.onRequest(_ctx(method: HttpMethod.get, metaIndex: index));
    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['items'], isEmpty);
  });

  test('non-GET method returns 405', () async {
    final index = MetaIndex();
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, metaIndex: index),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
