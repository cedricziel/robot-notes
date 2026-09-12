import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/mcp_auth_middleware.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

const _publicUrl = 'https://notes.example.com';

Config _config() => const Config(
      apiKey: 'rn_static_key',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: _publicUrl,
    );

RequestContext _ctx({
  Map<String, String> headers = const {},
  TokenStore? tokenStore,
  Actor actor = Actor.unknown,
  Uri? uri,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.post);
  when(() => req.uri).thenReturn(uri ?? Uri.parse('$_publicUrl/mcp'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(_config());
  when(() => ctx.read<Actor>()).thenReturn(actor);
  if (tokenStore != null) {
    when(() => ctx.read<TokenStore>()).thenReturn(tokenStore);
  }
  // `provide<T>()` must return a fresh context whose `read<T>()` yields the
  // supplied value — mirrors the stub in actor_middleware_test.dart.
  when(() => ctx.provide<McpPrincipal>(any())).thenAnswer((invocation) {
    final create =
        invocation.positionalArguments.first as McpPrincipal Function();
    final value = create();
    when(() => ctx.read<McpPrincipal>()).thenReturn(value);
    return ctx;
  });
  return ctx;
}

Future<Response> _run(RequestContext context) async {
  Future<Response> inner(RequestContext c) async {
    final principal = c.read<McpPrincipal>();
    return Response.json(
      body: {'actor': principal.actor, 'scopes': principal.scopes.toList()},
    );
  }

  return mcpAuth()(inner)(context);
}

void main() {
  late TokenStore tokenStore;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('robot-notes-mcp-auth-test-');
    tokenStore = TokenStore(dir: Directory('${tmp.path}/tokens'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('missing credential is 401 with resource_metadata and no error param',
      () async {
    final response = await _run(_ctx(tokenStore: tokenStore));
    expect(response.statusCode, HttpStatus.unauthorized);
    expect(await response.json(), {'error': 'unauthorized'});
    final challenge = response.headers['WWW-Authenticate']!;
    expect(
      challenge,
      contains(
        'resource_metadata="$_publicUrl/.well-known/'
        'oauth-protected-resource/mcp"',
      ),
    );
    expect(challenge, isNot(contains('error=')));
  });

  test('unknown token is 401 with error="invalid_token"', () async {
    final response = await _run(
      _ctx(
        headers: {'Authorization': 'Bearer not-a-real-token'},
        tokenStore: tokenStore,
      ),
    );
    expect(response.statusCode, HttpStatus.unauthorized);
    final challenge = response.headers['WWW-Authenticate']!;
    expect(challenge, contains('error="invalid_token"'));
    expect(
      challenge,
      contains(
        'resource_metadata="$_publicUrl/.well-known/'
        'oauth-protected-resource/mcp"',
      ),
    );
  });

  test('static key yields a principal from X-Actor with both scopes', () async {
    final response = await _run(
      _ctx(
        headers: {'Authorization': 'Bearer rn_static_key'},
        tokenStore: tokenStore,
        actor: const Actor('research-bot'),
      ),
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = await response.json() as Map<String, dynamic>;
    expect(body['actor'], 'research-bot');
    expect(body['scopes'], containsAll(['notes:read', 'notes:write']));
  });

  test(
    'valid access token yields the grant actor and scopes, ignoring X-Actor',
    () async {
      final issued = await tokenStore.issue(
        clientId: 'client-1',
        actor: 'desk-assistant',
        scopes: {'notes:read'},
        resource: '$_publicUrl/mcp',
        grantId: 'grant-1',
      );
      final response = await _run(
        _ctx(
          headers: {'Authorization': 'Bearer ${issued.accessToken}'},
          tokenStore: tokenStore,
          actor: const Actor('spoofed'),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await response.json() as Map<String, dynamic>;
      expect(body['actor'], 'desk-assistant');
      expect(body['scopes'], ['notes:read']);
    },
  );

  test('refresh token presented as bearer credential is rejected', () async {
    final issued = await tokenStore.issue(
      clientId: 'client-1',
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: '$_publicUrl/mcp',
      grantId: 'grant-1',
    );
    final response = await _run(
      _ctx(
        headers: {'Authorization': 'Bearer ${issued.refreshToken}'},
        tokenStore: tokenStore,
      ),
    );
    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('token bound to a different resource is rejected', () async {
    final issued = await tokenStore.issue(
      clientId: 'client-1',
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: 'https://other.example/mcp',
      grantId: 'grant-1',
    );
    final response = await _run(
      _ctx(
        headers: {'Authorization': 'Bearer ${issued.accessToken}'},
        tokenStore: tokenStore,
      ),
    );
    expect(response.statusCode, HttpStatus.unauthorized);
    expect(
      response.headers['WWW-Authenticate'],
      contains('error="invalid_token"'),
    );
  });

  test('token in the query string is ignored (still 401)', () async {
    final issued = await tokenStore.issue(
      clientId: 'client-1',
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: '$_publicUrl/mcp',
      grantId: 'grant-1',
    );
    final ctx = _ctx(
      tokenStore: tokenStore,
      uri: Uri.parse('$_publicUrl/mcp?access_token=${issued.accessToken}'),
    );
    final response = await _run(ctx);
    expect(response.statusCode, HttpStatus.unauthorized);
  });
}
