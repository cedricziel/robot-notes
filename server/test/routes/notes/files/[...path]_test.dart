import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/files/[...path].dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({required HttpMethod method, required Storage storage}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Storage>()).thenReturn(storage);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-files-path-test-');

void main() {
  late Directory tmp;
  late Storage storage;

  setUp(() {
    tmp = _tempDir();
    storage = Storage(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('retrieves a previously uploaded file with the right content-type',
      () async {
    final dir = Directory('${tmp.path}/content/Ideas')
      ..createSync(recursive: true);
    File('${dir.path}/diagram.png').writeAsBytesSync([1, 2, 3]);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Ideas/diagram.png',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers['content-type'], 'image/png');
    final bytes = await res.bytes().expand((c) => c).toList();
    expect(bytes, [1, 2, 3]);
  });

  test('a nested path resolves correctly', () async {
    final dir = Directory('${tmp.path}/content/Projects/Alpha')
      ..createSync(recursive: true);
    File('${dir.path}/notes.pdf').writeAsStringSync('hello');

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Projects/Alpha/notes.pdf',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(utf8.decode(await res.bytes().expand((c) => c).toList()), 'hello');
  });

  test('a path with no file returns 404', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'does-not-exist.png',
    );

    expect(res.statusCode, HttpStatus.notFound);
  });

  test('an unrecognized extension falls back to application/octet-stream',
      () async {
    Directory('${tmp.path}/content').createSync(recursive: true);
    File('${tmp.path}/content/mystery.nonexistentextension')
        .writeAsBytesSync([1]);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'mystery.nonexistentextension',
    );

    expect(res.headers['content-type'], 'application/octet-stream');
  });

  test('a traversal attempt is rejected with 400', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Projects/../etc',
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, storage: storage),
      'diagram.png',
    );

    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
