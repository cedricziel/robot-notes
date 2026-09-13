import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/attachments.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/attachments/[...path].dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required AttachmentStore attachmentStore,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<AttachmentStore>()).thenReturn(attachmentStore);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-attachments-get-test-');

void main() {
  late Directory tmp;
  late AttachmentStore store;

  setUp(() {
    tmp = _tempDir();
    store = AttachmentStore(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, attachmentStore: store),
      'diagram.png',
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });

  test('retrieves a previously uploaded file with the right content-type',
      () async {
    await store.write(
      path: 'Ideas',
      filename: 'diagram.png',
      bytes: Stream.value(List.filled(4, 1)),
      maxBytes: 1024,
    );

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
      'Ideas/diagram.png',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers[HttpHeaders.contentTypeHeader], 'image/png');
    final bytes = await res.bytes().expand((chunk) => chunk).toList();
    expect(bytes, List.filled(4, 1));
  });

  test('resolves a nested path', () async {
    await store.write(
      path: 'Projects/Alpha',
      filename: 'note.txt',
      bytes: Stream.value('hi'.codeUnits),
      maxBytes: 1024,
    );

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
      'Projects/Alpha/note.txt',
    );

    expect(res.statusCode, HttpStatus.ok);
  });

  test('a path with no file returns 404', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
      'does-not-exist.png',
    );
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('an unrecognized extension falls back to application/octet-stream',
      () async {
    await store.write(
      path: '',
      filename: 'mystery.xyz123',
      bytes: Stream.value('hi'.codeUnits),
      maxBytes: 1024,
    );

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
      'mystery.xyz123',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(
      res.headers[HttpHeaders.contentTypeHeader],
      'application/octet-stream',
    );
  });

  test('a traversal attempt is rejected with 400', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
      '../../etc/passwd',
    );
    expect(res.statusCode, HttpStatus.badRequest);
  });
}
