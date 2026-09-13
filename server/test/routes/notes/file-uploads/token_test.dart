import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/config.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/file-uploads/[token].dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required UploadSessionStore sessions,
  Config? config,
  Stream<List<int>>? body,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.headers).thenReturn(headers);
  when(req.bytes).thenAnswer((_) => body ?? const Stream.empty());
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<UploadSessionStore>()).thenReturn(sessions);
  when(() => ctx.read<Config>()).thenReturn(
    config ??
        const Config(apiKey: 'k', dataDir: '/tmp', port: 0, lockTtlSeconds: 60),
  );
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-upload-put-route-test-');

void main() {
  late Directory tmp;
  late UploadSessionStore sessions;

  setUp(() {
    tmp = _tempDir();
    sessions = UploadSessionStore(
      stagingDir: Directory('${tmp.path}/uploads'),
      sweepInterval: null,
    );
  });

  tearDown(() {
    sessions.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('completes a reserved upload with no Authorization needed', () async {
    final reserved = sessions.reserve(
      path: 'Ideas',
      filename: 'photo.png',
      maxBytes: 1024,
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.put,
        sessions: sessions,
        body: Stream.value([1, 2, 3]),
        headers: {'content-type': 'image/png'},
      ),
      reserved.token,
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    expect(body['token'], reserved.token);
    expect(body['size'], 3);
    expect(body['content_type'], 'image/png');
  });

  test('a missing token returns 404', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.put, sessions: sessions, body: Stream.value([1])),
      'nope',
    );

    expect(res.statusCode, HttpStatus.notFound);
  });

  test('an already-completed token returns 404', () async {
    final reserved = sessions.reserve(
      path: 'Ideas',
      filename: 'photo.png',
      maxBytes: 1024,
    );
    await sessions.complete(token: reserved.token, bytes: Stream.value([1]));

    final res = await route.onRequest(
      _ctx(method: HttpMethod.put, sessions: sessions, body: Stream.value([2])),
      reserved.token,
    );

    expect(res.statusCode, HttpStatus.notFound);
  });

  test('an oversized PUT returns 413 and leaves no staged file', () async {
    final reserved = sessions.reserve(
      path: 'Ideas',
      filename: 'big.bin',
      maxBytes: 5,
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.put,
        sessions: sessions,
        body: Stream.fromIterable([List.filled(10, 1)]),
      ),
      reserved.token,
    );

    expect(res.statusCode, HttpStatus.requestEntityTooLarge);
    expect(
      File('${tmp.path}/uploads/${reserved.token}.bin').existsSync(),
      isFalse,
    );
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, sessions: sessions),
      'anything',
    );

    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
