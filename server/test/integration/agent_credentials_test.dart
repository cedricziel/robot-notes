import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_otel_api/dart_otel_api.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/actor.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/mcp/mcp_auth_middleware.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/root_middleware.dart';
import 'package:server/src/ws/connection.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.start();
  });
  tearDown(() async {
    await app.close();
  });

  test('REST and MCP bind recorded identity and ignore actor headers',
      () async {
    final credential =
        await app.deps.agentCredentials.issue(actor: 'recorded-agent');
    final mcp = ((RequestContext context) async {
      final principal = context.read<McpPrincipal>();
      return Response.json(
        body: {'id': principal.principalId, 'actor': principal.actor},
      );
    }).use(mcpAuth(agentCredentials: app.deps.agentCredentials));
    final handler = applyRootMiddleware(
      (context) async {
        if (context.request.uri.path == '/mcp') return mcp(context);
        final principal = context.read<RestPrincipal>();
        return Response.json(
          body: {
            'id': principal.principalId,
            'actor': context.read<Actor>().name,
          },
        );
      },
      deps: app.deps,
      config: app.config,
      tracerProvider: const NoopTracerProvider(),
    );
    final server = await serve(handler, InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://${server.address.host}:${server.port}';
    final rest = await http.get(
      Uri.parse('$base/notes'),
      headers: _headers(credential.secret),
    );
    final result = await http.post(
      Uri.parse('$base/mcp'),
      headers: _headers(credential.secret),
    );
    expect(
      jsonDecode(rest.body),
      {'id': 'agent:${credential.record.id}', 'actor': 'recorded-agent'},
    );
    expect(
      jsonDecode(result.body),
      {'id': 'agent:${credential.record.id}', 'actor': 'recorded-agent'},
    );
  });

  test('OAuth knowledge scopes require consent and survive refresh', () async {
    final defaults = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
    );
    final defaultRecord =
        await app.deps.tokenStore.lookupAccess(defaults.accessToken);
    expect(defaultRecord!.scopes, {'notes:read', 'notes:write'});
    final explicit = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:read knowledge:review',
    );
    final before = await app.deps.tokenStore.lookupAccess(explicit.accessToken);
    final refreshed = await http.post(
      Uri.parse('${app.baseUrl}/oauth/token'),
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': explicit.refreshToken,
        'client_id': explicit.clientId,
      },
    );
    expect(refreshed.statusCode, 200, reason: refreshed.body);
    final body = jsonDecode(refreshed.body) as Map<String, dynamic>;
    final after =
        await app.deps.tokenStore.lookupAccess(body['access_token'] as String);
    expect(after!.grantId, before!.grantId);
    expect(after.scopes, {'notes:read', kScopeKnowledgeReview});
  });

  test('agent WebSocket identity rejects spoofing and closes on revocation',
      () async {
    final credential =
        await app.deps.agentCredentials.issue(actor: 'recorded-agent');
    final sink = _Sink();
    final connection = WsConnection(
      id: 'identity-test',
      sink: sink,
      broadcaster: app.deps.broadcaster,
      presence: app.deps.presence,
      apiKey: app.config.apiKey,
      tokenStore: app.deps.tokenStore,
      agentCredentials: app.deps.agentCredentials,
      restResource: app.baseUrl,
    )..start();
    addTearDown(connection.handleDone);
    await connection.handleMessage(
      jsonEncode(
        {'type': 'auth', 'key': credential.secret, 'actor': 'operator'},
      ),
    );
    expect(connection.actor!.name, 'recorded-agent');
    expect(connection.principalId, 'agent:${credential.record.id}');
    await app.deps.agentCredentials.revoke(credential.record.id);
    await Future<void>.delayed(Duration.zero);
    expect(connection.isClosed, isTrue);
    expect(sink.code, 4001);
  });

  test('default agent persists without its secret or elevated scopes',
      () async {
    final credential = await app.deps.agentCredentials.issue(actor: 'agent');
    final reopened = AgentCredentialStore(dir: app.deps.agentCredentials.dir);
    final record = await reopened.lookup(credential.secret);
    expect(record!.id, credential.record.id);
    expect(
      record.scopes,
      {'notes:read', 'notes:write', kScopeKnowledgePropose},
    );
    expect(record.vaultIds, {'default'});
    final files = app.deps.agentCredentials.dir.listSync().cast<File>();
    expect(files.single.readAsStringSync(), isNot(contains(credential.secret)));
    expect(files.single.path, isNot(contains(credential.secret)));
  });

  test('agent can write ordinary notes but cannot mint invites or credentials',
      () async {
    final credential =
        await app.deps.agentCredentials.issue(actor: 'recorded-agent');
    final headers = _headers(credential.secret);
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: headers,
      body: jsonEncode({'title': 'Owned', 'content': 'hello'}),
    );
    expect(created.statusCode, 201, reason: created.body);
    final invites = await http.post(
      Uri.parse('${app.baseUrl}/invites'),
      headers: headers,
      body: jsonEncode({'label': 'escalation'}),
    );
    final credentials = await http.post(
      Uri.parse('${app.baseUrl}/credentials'),
      headers: headers,
      body: jsonEncode({'actor': 'escalation'}),
    );
    expect(invites.statusCode, 403, reason: invites.body);
    expect(credentials.statusCode, 403, reason: credentials.body);
  });

  test('operator can provision and revoke without exposing listed secrets',
      () async {
    final provisioned = await http.post(
      Uri.parse('${app.baseUrl}/credentials'),
      headers: app.headers(),
      body: jsonEncode({'actor': 'agent'}),
    );
    expect(provisioned.statusCode, 201, reason: provisioned.body);
    final body = jsonDecode(provisioned.body) as Map<String, dynamic>;
    final secret = body['secret'] as String;
    final listing = await http.get(
      Uri.parse('${app.baseUrl}/credentials'),
      headers: app.headers(),
    );
    expect(listing.statusCode, 200);
    expect(listing.body, isNot(contains(secret)));
    expect(listing.body, isNot(contains('secret_hash')));
    final revoked = await http.delete(
      Uri.parse('${app.baseUrl}/credentials/${body['id']}'),
      headers: app.headers(),
    );
    expect(revoked.statusCode, 204);
    final denied = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: _headers(secret),
    );
    expect(denied.statusCode, 401);
  });

  test('read-only credential cannot mutate through REST or MCP', () async {
    final credential = await app.deps.agentCredentials
        .issue(actor: 'reader', scopes: {'notes:read'});
    final rest = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: _headers(credential.secret),
      body: jsonEncode({'title': 'Denied', 'content': 'x'}),
    );
    expect(rest.statusCode, 403);
    final mcp = await _mcp(
      app,
      credential.secret,
      'create_note',
      {'title': 'Denied', 'content': 'x'},
    );
    expect((mcp['result'] as Map<String, dynamic>)['isError'], isTrue);
    expect(mcp.toString(), contains('insufficient_scope'));
  });

  test('MCP uses recorded actor and rejects foreign vault and revoked key',
      () async {
    final credential =
        await app.deps.agentCredentials.issue(actor: 'recorded-agent');
    final created = await _mcp(
      app,
      credential.secret,
      'create_note',
      {'title': 'MCP', 'content': 'hello'},
    );
    expect(
      (created['result'] as Map<String, dynamic>)['isError'],
      isNot(isTrue),
    );
    final denied = await _mcp(
      app,
      credential.secret,
      'list_notes',
      {'vault_id': 'foreign'},
    );
    expect(denied.toString(), contains('vault_access_denied'));
    await app.deps.agentCredentials.revoke(credential.record.id);
    final revoked = await http.post(
      Uri.parse('${app.baseUrl}/mcp'),
      headers: _headers(credential.secret),
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
    );
    expect(revoked.statusCode, 401);
  });

  test('credential cannot read another vault through REST', () async {
    final vault = await app.deps.vaults!.create('Private');
    final credential = await app.deps.agentCredentials.issue(actor: 'agent');
    final denied = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: {..._headers(credential.secret), 'X-Vault-Id': vault['id']!},
    );
    expect(denied.statusCode, 403, reason: denied.body);
  });

  test('WebSocket rejects a foreign vault and revoked credential', () async {
    final credential =
        await app.deps.agentCredentials.issue(actor: 'recorded-agent');
    final vault = await app.deps.vaults!.create('Private');
    final foreign = WebSocketChannel.connect(
      Uri.parse('${app.wsUrl}?vault_id=${vault['id']}'),
    );
    await foreign.ready;
    final done = foreign.stream.drain<void>();
    foreign.sink.add(
      jsonEncode(
        {'type': 'auth', 'key': credential.secret, 'actor': 'operator'},
      ),
    );
    await done;
    expect(foreign.closeCode, 4001);
    await app.deps.agentCredentials.revoke(credential.record.id);
    final revoked = WebSocketChannel.connect(Uri.parse(app.wsUrl));
    await revoked.ready;
    final revokedDone = revoked.stream.drain<void>();
    revoked.sink.add(jsonEncode({'type': 'auth', 'key': credential.secret}));
    await revokedDone;
    expect(revoked.closeCode, 4001);
  });
}

Map<String, String> _headers(String secret) => {
      'Authorization': 'Bearer $secret',
      'Content-Type': 'application/json',
      'X-Actor': 'operator',
    };

Future<Map<String, dynamic>> _mcp(
  TestApp app,
  String secret,
  String name,
  Map<String, dynamic> args,
) async {
  final response = await http.post(
    Uri.parse('${app.baseUrl}/mcp'),
    headers: _headers(secret),
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    }),
  );
  expect(response.statusCode, 200, reason: response.body);
  return jsonDecode(response.body) as Map<String, dynamic>;
}

class _Sink implements WsSink {
  int? code;
  @override
  bool get isClosed => code != null;
  @override
  void close(int closeCode, String reason) {
    code = closeCode;
  }

  @override
  void send(String data) {}
}
