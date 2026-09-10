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

    test('GET /invites/{token}/onboarding.txt bypasses auth', () async {
      final ctx = _ctx(
        path: '/invites/abc-123/onboarding.txt',
        method: HttpMethod.get,
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response(body: 'bundle'),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.body(), 'bundle');
    });

    test('non-GET on onboarding URL still requires auth', () async {
      final ctx = _ctx(
        path: '/invites/abc-123/onboarding.txt',
        method: HttpMethod.post,
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('GET /invites (without onboarding suffix) still requires auth',
        () async {
      final ctx = _ctx(path: '/invites', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('POST /invites still requires auth', () async {
      final ctx = _ctx(path: '/invites', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('DELETE /invites/{token} still requires auth', () async {
      final ctx = _ctx(path: '/invites/abc', method: HttpMethod.delete);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('GET /.well-known/oauth-protected-resource bypasses auth', () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-protected-resource',
        method: HttpMethod.get,
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'ok': true}),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('GET /.well-known/oauth-protected-resource/mcp bypasses auth',
        () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-protected-resource/mcp',
        method: HttpMethod.get,
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'ok': true}),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('GET /.well-known/oauth-authorization-server bypasses auth', () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-authorization-server',
        method: HttpMethod.get,
      );
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'ok': true}),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('POST /oauth/register bypasses auth', () async {
      final ctx = _ctx(path: '/oauth/register', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response(statusCode: HttpStatus.created),
      );
      expect(response.statusCode, HttpStatus.created);
    });

    test('GET /oauth/register still requires auth', () async {
      final ctx = _ctx(path: '/oauth/register', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('GET /oauth/authorize bypasses auth', () async {
      final ctx = _ctx(path: '/oauth/authorize', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response(body: 'consent'),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('POST /oauth/authorize bypasses auth', () async {
      final ctx = _ctx(path: '/oauth/authorize', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response(statusCode: HttpStatus.found),
      );
      expect(response.statusCode, HttpStatus.found);
    });

    test('POST /oauth/token bypasses auth', () async {
      final ctx = _ctx(path: '/oauth/token', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response.json(body: const {'access_token': 'x'}),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('GET /oauth/token still requires auth', () async {
      final ctx = _ctx(path: '/oauth/token', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('POST /oauth/revoke bypasses auth', () async {
      final ctx = _ctx(path: '/oauth/revoke', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
        handlerResponse: Response(),
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test('every method on /mcp bypasses the static key', () async {
      for (final method in [
        HttpMethod.get,
        HttpMethod.post,
        HttpMethod.delete,
        HttpMethod.put,
        HttpMethod.patch,
        HttpMethod.head,
        HttpMethod.options,
      ]) {
        final ctx = _ctx(path: '/mcp', method: method);
        final response = await _runMiddleware(
          bearerAuth(configuredKey: configured),
          ctx,
          handlerResponse: Response(body: 'mcp'),
        );
        expect(response.statusCode, HttpStatus.ok, reason: '$method');
      }
    });

    test('a made-up /oauthx path still requires auth', () async {
      final ctx = _ctx(path: '/oauthx', method: HttpMethod.get);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('a made-up /oauth/other path still requires auth', () async {
      final ctx = _ctx(path: '/oauth/other', method: HttpMethod.post);
      final response = await _runMiddleware(
        bearerAuth(configuredKey: configured),
        ctx,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test(
        '/keys, /rotate, /auth/rotate are not exempt but reach the app '
        'unauthenticated calls still 401', () async {
      for (final path in ['/keys', '/rotate', '/auth/rotate']) {
        final ctx = _ctx(path: path, method: HttpMethod.get);
        final response = await _runMiddleware(
          bearerAuth(configuredKey: configured),
          ctx,
        );
        expect(response.statusCode, HttpStatus.unauthorized, reason: path);
      }
    });

    test(
        '/keys, /rotate, /auth/rotate with a valid key reach the app, '
        'which 404s (no route registered)', () async {
      for (final path in ['/keys', '/rotate', '/auth/rotate']) {
        final ctx = _ctx(
          path: path,
          method: HttpMethod.get,
          headers: {'Authorization': 'Bearer $configured'},
        );
        final response = await _runMiddleware(
          bearerAuth(configuredKey: configured),
          ctx,
          handlerResponse: Response(statusCode: HttpStatus.notFound),
        );
        expect(response.statusCode, HttpStatus.notFound, reason: path);
      }
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
