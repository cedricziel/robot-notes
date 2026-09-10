import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/config.dart';
import 'package:server/src/well_known_middleware.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

Config _config({String? publicUrl}) => Config(
      apiKey: 'rn_test',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: publicUrl,
    );

RequestContext _ctx({
  required String path,
  HttpMethod method = HttpMethod.get,
  Map<String, String> headers = const {'host': 'notes.example.com'},
  Config? config,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('http://localhost$path'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(config ?? _config());
  return ctx;
}

Future<Response> _run(
  Middleware mw,
  RequestContext context, {
  Response Function()? handler,
}) async {
  Future<Response> inner(RequestContext _) async =>
      (handler ?? () => Response(body: 'fallthrough'))();
  return mw(inner)(context);
}

void main() {
  group('wellKnownMiddleware', () {
    test('serves protected-resource metadata without auth', () async {
      final ctx = _ctx(path: '/.well-known/oauth-protected-resource');
      final response = await _run(wellKnownMiddleware(), ctx);

      expect(response.statusCode, HttpStatus.ok);
      final body = await response.json() as Map<String, dynamic>;
      expect(body['resource'], 'http://notes.example.com/mcp');
      expect(body['authorization_servers'], ['http://notes.example.com']);
      expect(body['bearer_methods_supported'], ['header']);
      expect(body['scopes_supported'], ['notes:read', 'notes:write']);
      expect(body['resource_name'], 'robot-notes');
    });

    test('the /mcp variant matches the root document', () async {
      final rootRes = await _run(
        wellKnownMiddleware(),
        _ctx(path: '/.well-known/oauth-protected-resource'),
      );
      final mcpRes = await _run(
        wellKnownMiddleware(),
        _ctx(path: '/.well-known/oauth-protected-resource/mcp'),
      );

      expect(await mcpRes.json(), await rootRes.json());
    });

    test('serves authorization-server metadata without auth', () async {
      final ctx = _ctx(path: '/.well-known/oauth-authorization-server');
      final response = await _run(wellKnownMiddleware(), ctx);

      expect(response.statusCode, HttpStatus.ok);
      final body = await response.json() as Map<String, dynamic>;
      expect(body['issuer'], 'http://notes.example.com');
      expect(
        body['authorization_endpoint'],
        'http://notes.example.com/oauth/authorize',
      );
      expect(body['token_endpoint'], 'http://notes.example.com/oauth/token');
      expect(
        body['registration_endpoint'],
        'http://notes.example.com/oauth/register',
      );
      expect(
        body['revocation_endpoint'],
        'http://notes.example.com/oauth/revoke',
      );
      expect(body['response_types_supported'], ['code']);
      expect(
        body['grant_types_supported'],
        ['authorization_code', 'refresh_token'],
      );
      expect(body['code_challenge_methods_supported'], ['S256']);
      expect(
        body['token_endpoint_auth_methods_supported'],
        ['none', 'client_secret_post', 'client_secret_basic'],
      );
      expect(body['scopes_supported'], ['notes:read', 'notes:write']);
    });

    test('respects a configured public URL', () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-authorization-server',
        config: _config(publicUrl: 'https://notes.example.com'),
        headers: {'host': '10.0.0.5:8080'},
      );
      final response = await _run(wellKnownMiddleware(), ctx);
      final body = await response.json() as Map<String, dynamic>;
      expect(body['issuer'], 'https://notes.example.com');
    });

    test('non-GET on a discovery path is 405', () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-protected-resource',
        method: HttpMethod.post,
      );
      final response = await _run(wellKnownMiddleware(), ctx);
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('non-GET on the authorization-server path is 405', () async {
      final ctx = _ctx(
        path: '/.well-known/oauth-authorization-server',
        method: HttpMethod.put,
      );
      final response = await _run(wellKnownMiddleware(), ctx);
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('other /.well-known paths pass through (404 naturally)', () async {
      final ctx = _ctx(path: '/.well-known/unrelated');
      final response = await _run(
        wellKnownMiddleware(),
        ctx,
        handler: () => Response(statusCode: HttpStatus.notFound),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('unrelated paths pass through to the handler', () async {
      final ctx = _ctx(path: '/notes');
      final response = await _run(
        wellKnownMiddleware(),
        ctx,
        handler: () => Response(body: 'api'),
      );
      expect(await response.body(), 'api');
    });
  });
}
