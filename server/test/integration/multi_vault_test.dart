import 'dart:convert';
import 'package:web_socket_channel/io.dart';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:server/src/app_deps.dart';

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

  Future<String> createVault(String name) async {
    final res = await http.post(Uri.parse('${app.baseUrl}/vaults'),
        headers: app.headers(), body: jsonEncode({'name': name}));
    expect(res.statusCode, 201, reason: res.body);
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  Future<Map<String, dynamic>> mcp(String token, String name,
      [Map<String, Object?> args = const {}]) async {
    final res = await http.post(Uri.parse('${app.baseUrl}/mcp'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': args}
        }));
    expect(res.statusCode, 200, reason: res.body);
    expect((jsonDecode(res.body) as Map<String, dynamic>)['error'], isNull,
        reason: res.body);
    return (jsonDecode(res.body) as Map<String, dynamic>)['result']
        as Map<String, dynamic>;
  }

  test('notes and searches are isolated and catalog survives restart',
      () async {
    final id = await createVault('Work');
    final created = await http.post(Uri.parse('${app.baseUrl}/notes'),
        headers: {...app.headers(), 'X-Vault-Id': id},
        body: jsonEncode(
            {'title': 'Private work', 'content': 'vaultonlykeyword'}));
    expect(created.statusCode, 201, reason: created.body);
    final noteId = (jsonDecode(created.body) as Map<String, dynamic>)['id'];
    final other = await http.get(Uri.parse('${app.baseUrl}/notes/$noteId'),
        headers: app.headers());
    expect(other.statusCode, 404);
    final notes = await http.get(Uri.parse('${app.baseUrl}/notes'),
        headers: app.headers());
    expect(notes.body, isNot(contains('Private work')));
    final search = await http.get(
        Uri.parse('${app.baseUrl}/search?q=vaultonlykeyword'),
        headers: app.headers());
    expect(search.body, isNot(contains('Private work')));
    final selected = await http.get(
        Uri.parse('${app.baseUrl}/search?q=vaultonlykeyword'),
        headers: {...app.headers(), 'X-Vault-Id': id});
    expect(selected.body, contains('Private work'));
    final renamed = await http.patch(Uri.parse('${app.baseUrl}/vaults/$id'),
        headers: app.headers(), body: jsonEncode({'name': 'Projects'}));
    expect(renamed.statusCode, 200);
    await app.close(deleteDir: false);
    final deps = await AppDeps.bootstrap(app.config);
    final server = await startTestServer(deps: deps, config: app.config);
    app = TestApp.wrap(server, deps, app.config, app.tmpDir);
    final catalog = await http.get(Uri.parse('${app.baseUrl}/vaults'),
        headers: app.headers());
    expect(catalog.body, contains('Projects'));
    final persisted = await http.get(Uri.parse('${app.baseUrl}/notes/$noteId'),
        headers: {...app.headers(), 'X-Vault-Id': id});
    expect(persisted.statusCode, 200);
    expect(persisted.body, contains('Private work'));
  });

  test('MCP consent and refresh retain exact vault selection', () async {
    final allowed = await createVault('Allowed');
    final secondAllowed = await createVault('Also allowed');
    final denied = await createVault('Denied');
    final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
        vaultIds: {allowed, secondAllowed});
    final listed = await mcp(grant.accessToken, 'list_vaults');
    expect(jsonEncode(listed), contains(allowed));
    expect(jsonEncode(listed), contains(secondAllowed));
    expect(jsonEncode(listed), isNot(contains(denied)));
    final forbidden = await mcp(grant.accessToken, 'create_note',
        {'vault_id': denied, 'title': 'Leak', 'content': ''});
    expect(forbidden['structuredContent']['error'], 'vault_access_denied');
    final defaultDenied = await mcp(grant.accessToken, 'list_notes');
    expect(defaultDenied['structuredContent']['error'], 'vault_access_denied');
    final created = await mcp(grant.accessToken, 'create_note',
        {'vault_id': allowed, 'title': 'Allowed note', 'content': ''});
    expect(created['isError'], isNot(true));
    final refreshed =
        await http.post(Uri.parse('${app.baseUrl}/oauth/token'), body: {
      'grant_type': 'refresh_token',
      'client_id': grant.clientId,
      'refresh_token': grant.refreshToken
    });
    expect(refreshed.statusCode, 200);
    final token = (jsonDecode(refreshed.body)
        as Map<String, dynamic>)['access_token'] as String;
    final afterRefresh = await mcp(token, 'list_notes', {'vault_id': denied});
    expect(afterRefresh['structuredContent']['error'], 'vault_access_denied');
    final newVault = await createVault('Created later');
    final later = await mcp(token, 'list_notes', {'vault_id': newVault});
    expect(later['structuredContent']['error'], 'vault_access_denied');
  });

  test('REST grants filter catalog and enforce vault before note access',
      () async {
    final allowed = await createVault('Allowed');
    final denied = await createVault('Denied');
    final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
        resource: app.baseUrl,
        vaultIds: {allowed});
    final headers = {
      'Authorization': 'Bearer ${grant.accessToken}',
      'X-Vault-Id': allowed
    };
    final list =
        await http.get(Uri.parse('${app.baseUrl}/vaults'), headers: headers);
    expect(list.statusCode, 200);
    expect(list.body, contains(allowed));
    expect(list.body, isNot(contains(denied)));
    final notes =
        await http.get(Uri.parse('${app.baseUrl}/notes'), headers: headers);
    expect(notes.statusCode, 200);
    final forbidden = await http.get(Uri.parse('${app.baseUrl}/notes'),
        headers: {...headers, 'X-Vault-Id': denied});
    expect(forbidden.statusCode, 403);
    final management = await http.post(Uri.parse('${app.baseUrl}/vaults'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': 'Escalation'}));
    expect(management.statusCode, 403);
  });
  test('two-phase uploads remain bound to their selected vault', () async {
    final id = await createVault('Files');
    final reserved = await mcp(app.config.apiKey, 'request_upload',
        {'vault_id': id, 'path': '', 'filename': 'sample.txt'});
    final payload = reserved['structuredContent'] as Map<String, dynamic>;
    expect(payload['upload_url'], contains('vault_id=$id'));
    final put = await http.put(
        Uri.parse('${app.baseUrl}${payload['upload_url']}'),
        body: 'hello');
    expect(put.statusCode, 200, reason: put.body);
    final wrong = await mcp(
        app.config.apiKey, 'finalize_upload', {'token': payload['token']});
    expect(wrong['isError'], isTrue);
    final finalized = await mcp(app.config.apiKey, 'finalize_upload',
        {'vault_id': id, 'token': payload['token']});
    expect(finalized['isError'], isNot(true), reason: jsonEncode(finalized));
    final target = await app.deps.vaults!.open(id);
    expect(
        target.storage.contentDir
            .listSync()
            .any((f) => f.path.endsWith('sample.txt')),
        isTrue);
    expect(
        app.deps.storage.contentDir.existsSync() &&
            app.deps.storage.contentDir
                .listSync()
                .any((f) => f.path.endsWith('sample.txt')),
        isFalse);
  });

  test('WebSocket rejects a token without access to the selected vault',
      () async {
    final allowed = await createVault('Allowed');
    final denied = await createVault('Denied');
    final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
        resource: app.baseUrl,
        vaultIds: {allowed});
    final rejected =
        IOWebSocketChannel.connect(Uri.parse('${app.wsUrl}?vault_id=$denied'));
    await rejected.ready;
    final messages = rejected.stream.toList();
    rejected.sink.add(jsonEncode(
        {'type': 'auth', 'key': grant.accessToken, 'actor': 'agent'}));
    await messages.timeout(const Duration(seconds: 5));
    expect(rejected.closeCode, 4001);
    final accepted =
        IOWebSocketChannel.connect(Uri.parse('${app.wsUrl}?vault_id=$allowed'));
    await accepted.ready;
    addTearDown(() => accepted.sink.close());
    final first = accepted.stream.first;
    accepted.sink.add(jsonEncode(
        {'type': 'auth', 'key': grant.accessToken, 'actor': 'agent'}));
    expect((jsonDecode(await first as String) as Map<String, dynamic>)['type'],
        'auth_ok');
  });
}
