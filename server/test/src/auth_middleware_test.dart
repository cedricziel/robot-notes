import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required String path,
  required HttpMethod method,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('http://localhost$path'));
  // Lower-case the header keys; dart_frog hands them down lower-case.
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  return ctx;
}

Future<Response> _runMiddleware(
  Middleware mw,
  RequestContext context, {
  Response? handlerResponse,
}) async {
  Future<Response> inner(RequestContext _) async =>
      handlerResponse ?? Response(body: 'ok');
  final wrapped = mw(inner);
  return wrapped(context);
}

void main() {
  const configured = 'rn_test_key';

  group('bearerAuth', () {
    test('rejects request with no Authorization header', () async {
      final ctx = _ctx(path: '/notes', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      expect(await response.json(), {'error': 'unauthorized'});
    });

    test('rejects malformed Authorization (no Bearer prefix)', () async {
      final ctx = _ctx(
        path: '/notes',
        method: HttpMethod.get,
        headers: {'Authorization': configured},
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('rejects Basic-scheme Authorization', () async {
      final ctx = _ctx(
        path: '/notes',
        method: HttpMethod.get,
        headers: {'Authorization': 'Basic abc'},
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('rejects mismatched bearer key', () async {
      final ctx = _ctx(
        path: '/notes',
        method: HttpMethod.get,
        headers: {'Authorization': 'Bearer wrong-key'},
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      expect(await response.json(), {'error': 'unauthorized'});
    });

    test('accepts the configured bearer key', () async {
      final ctx = _ctx(
        path: '/notes',
        method: HttpMethod.get,
        headers: {'Authorization': 'Bearer $configured'},
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.body(), 'ok');
    });

    test('accepts case-insensitive Bearer scheme', () async {
      final ctx = _ctx(
        path: '/notes',
        method: HttpMethod.get,
        headers: {'Authorization': 'bearer $configured'},
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('GET /healthz bypasses auth', () async {
      final ctx = _ctx(path: '/healthz', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'status': 'ok'}),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.json(), {'status': 'ok'});
    });

    test('non-GET /healthz still requires auth', () async {
      final ctx = _ctx(path: '/healthz', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('GET /ws bypasses HTTP auth (auth happens in-protocol)', () async {
      final ctx = _ctx(path: '/ws', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'ok': true}),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('GET /search without bearer is rejected', () async {
      final ctx = _ctx(path: '/search', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });
  });

  group('debugExtractBearer', () {
    test('returns null for missing or empty headers', () {
      expect(debugExtractBearer(null), isNull);
      expect(debugExtractBearer(''), isNull);
      expect(debugExtractBearer('   '), isNull);
    });

    test('returns null for non-bearer schemes', () {
      expect(debugExtractBearer('Basic abc'), isNull);
      expect(debugExtractBearer('Token abc'), isNull);
    });

    test('returns null when token is empty', () {
      expect(debugExtractBearer('Bearer'), isNull);
      expect(debugExtractBearer('Bearer '), isNull);
      expect(debugExtractBearer('Bearer    '), isNull);
    });

    test('extracts the token after Bearer', () {
      expect(debugExtractBearer('Bearer rn_x'), 'rn_x');
      expect(debugExtractBearer('Bearer  rn_x'), 'rn_x');
      expect(debugExtractBearer(' bearer rn_x '), 'rn_x');
    });
  });
}
