import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../../routes/mcp/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

const _publicUrl = 'https://notes.example.com';
const _principal = McpPrincipal.staticKey('tester');

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-mcp-route-test-');

Future<AppDeps> _bootstrap(Directory tmp) {
  final config = Config(
    apiKey: 'test-key',
    dataDir: tmp.path,
    port: 0,
    lockTtlSeconds: 60,
  );
  return AppDeps.bootstrap(config);
}

RequestContext _ctx({
  required HttpMethod method,
  required McpHandler handler,
  Map<String, String> headers = const {},
  Object? body,
  bool malformedJson = false,
  McpPrincipal principal = _principal,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('$_publicUrl/mcp'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  if (malformedJson) {
    when(req.json).thenAnswer(
      (_) async => throw const FormatException('bad json'),
    );
  } else if (body != null) {
    when(req.json).thenAnswer((_) async => body);
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(
    const Config(
      apiKey: 'test-key',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: _publicUrl,
    ),
  );
  when(() => ctx.read<McpHandler>()).thenReturn(handler);
  when(() => ctx.read<McpPrincipal>()).thenReturn(principal);
  return ctx;
}

void main() {
  late Directory tmp;
  late AppDeps deps;
  late McpHandler handler;

  setUp(() async {
    tmp = _tempDir();
    deps = await _bootstrap(tmp);
    handler = McpHandler(
      tools: McpToolRegistry.forDeps(deps),
      serverVersion: robotNotesVersion,
    );
  });

  tearDown(() async {
    await deps.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('GET is 405 with Allow: POST', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, handler: handler),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
    expect(res.headers['Allow'], 'POST');
  });

  test('DELETE is 405 with Allow: POST', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.delete, handler: handler),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
    expect(res.headers['Allow'], 'POST');
  });

  test(
    'Mcp-Session-Id header is ignored and never emitted in the response',
    () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          handler: handler,
          headers: const {'Mcp-Session-Id': 'anything'},
          body: {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        ),
      );
      expect(res.statusCode, HttpStatus.ok);
      final json = await res.json() as Map<String, dynamic>;
      final result = json['result'] as Map<String, dynamic>;
      expect(result['tools'], isA<List<dynamic>>());
      expect(res.headers.keys, isNot(contains('Mcp-Session-Id')));
    },
  );

  test('foreign Origin is 403 before the body is parsed', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        headers: const {'Origin': 'https://evil.example'},
        // Malformed body — if this were reached, we'd get 400, not 403.
      ),
    );
    expect(res.statusCode, HttpStatus.forbidden);
    expect(await res.json(), {'error': 'forbidden'});
  });

  test('own public origin is accepted', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        headers: const {'Origin': _publicUrl},
        body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      ),
    );
    expect(res.statusCode, HttpStatus.accepted);
  });

  test('loopback origin is accepted', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        headers: const {'Origin': 'http://localhost:53421'},
        body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      ),
    );
    expect(res.statusCode, HttpStatus.accepted);
  });

  test('absent Origin header is accepted', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      ),
    );
    expect(res.statusCode, HttpStatus.accepted);
  });

  test('unsupported MCP-Protocol-Version is 400', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        headers: const {'MCP-Protocol-Version': '2024-11-05'},
        body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      ),
    );
    expect(res.statusCode, HttpStatus.badRequest);
    expect(await res.json(), {'error': 'unsupported_protocol_version'});
  });

  test('supported MCP-Protocol-Version header is accepted', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        headers: const {'MCP-Protocol-Version': '2025-06-18'},
        body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      ),
    );
    expect(res.statusCode, HttpStatus.ok);
  });

  test('malformed JSON is 400 with JSON-RPC -32700', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, handler: handler, malformedJson: true),
    );
    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['id'], isNull);
    expect((json['error'] as Map<String, dynamic>)['code'], -32700);
  });

  test('batch request is 400 with JSON-RPC -32600', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        body: [
          {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        ],
      ),
    );
    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect((json['error'] as Map<String, dynamic>)['code'], -32600);
  });

  test('notification is 202 with an empty body', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      ),
    );
    expect(res.statusCode, HttpStatus.accepted);
    expect(await res.body(), isEmpty);
  });

  test('a request returns 200 with application/json', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        handler: handler,
        body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      ),
    );
    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers['content-type'], contains('application/json'));
    final json = await res.json() as Map<String, dynamic>;
    expect(json['result'], <String, dynamic>{});
  });
}
