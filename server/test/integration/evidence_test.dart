import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  const payload = '{"session_id":"session","kind":"turn","messages":'
      '[{"role":"tool","content":"archiveonlykeyword"}]}';
  final id = sha256.convert(utf8.encode(payload)).toString();
  setUp(() async => app = await TestApp.start());
  tearDown(() async => app.close());

  test('archive is isolated by vault and excluded from notes and search',
      () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/vaults'),
      headers: app.headers(),
      body: jsonEncode({'name': 'Evidence vault'}),
    );
    final vault = (jsonDecode(created.body) as Map)['id'] as String;
    final headers = {...app.headers(), 'X-Vault-Id': vault};
    final write = await http.put(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
      body: jsonEncode({'payload': payload, 'retention_days': 7}),
    );
    expect(write.statusCode, 200, reason: write.body);
    final other = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: app.headers(),
    );
    expect(other.statusCode, 404);
    final own = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
    );
    expect(own.body, write.body);
    final notes =
        await http.get(Uri.parse('${app.baseUrl}/notes'), headers: headers);
    expect((jsonDecode(notes.body) as Map)['items'], isEmpty);
    final search = await http.get(
      Uri.parse('${app.baseUrl}/search?q=archiveonlykeyword'),
      headers: headers,
    );
    expect((jsonDecode(search.body) as Map)['items'], isEmpty);
  });

  test(
      'read-only OAuth cannot archive and vault grants restrict evidence reads',
      () async {
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      resource: app.baseUrl,
      scope: 'notes:read',
    );
    final headers = {'Authorization': 'Bearer ${grant.accessToken}'};
    final write = await http.put(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
      body: jsonEncode({'payload': payload, 'retention_days': 7}),
    );
    expect(write.statusCode, 403);
    final read = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: {...headers, 'X-Vault-Id': 'outside-grant'},
    );
    expect(read.statusCode, 403);
  });
  test('collection ACL guards capture and reads under root curation', () async {
    final credential = await app.deps.agentCredentials.issue(actor: 'capture');
    final headers = {
      'Authorization': 'Bearer ${credential.secret}',
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse('${app.baseUrl}/evidence/$id');
    final body = jsonEncode({'payload': payload, 'retention_days': 7});
    await app.deps.authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true),
    );
    final captured = await http.put(uri, headers: headers, body: body);
    expect(captured.statusCode, 200, reason: captured.body);
    await app.deps.authorization.putEvidenceArchivePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgePolicyPatch(access: {KnowledgeAction.edit: {}}),
    );
    final deniedWrite = await http.put(uri, headers: headers, body: body);
    expect(deniedWrite.statusCode, 403, reason: deniedWrite.body);
    expect((await http.get(uri, headers: headers)).statusCode, 200);
    await app.deps.authorization.putEvidenceArchivePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final deniedRead = await http.get(uri, headers: headers);
    expect(deniedRead.statusCode, 403, reason: deniedRead.body);
    expect(app.deps.evidenceStore.read(id), isNotNull);
  });

  test(
      'evidence purge requires exact human capability and rejects agent origin',
      () async {
    final uri = Uri.parse('${app.baseUrl}/evidence/$id');
    app.deps.evidenceStore.put(id, payload, retentionDays: 7);
    final agent = await app.deps.agentCredentials.issue(
      actor: 'operator',
      scopes: {'notes:read', 'notes:write', 'vaults:manage', 'knowledge:purge'},
    );
    final deniedAgent = await http.delete(
      uri,
      headers: {'Authorization': 'Bearer ${agent.secret}'},
    );
    expect(deniedAgent.statusCode, 403, reason: deniedAgent.body);
    final deniedOrigin = await http.delete(
      uri,
      headers: {...app.headers(), 'X-Robot-Notes-Agent': 'true'},
    );
    expect(deniedOrigin.statusCode, 403, reason: deniedOrigin.body);
    expect(app.deps.evidenceStore.read(id), isNotNull);
    final human = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      resource: app.baseUrl,
      scope: 'notes:read knowledge:purge',
    );
    final purged = await http.delete(
      uri,
      headers: {'Authorization': 'Bearer ${human.accessToken}'},
    );
    expect(purged.statusCode, 204, reason: purged.body);
    expect(app.deps.evidenceStore.read(id), isNull);
  });
}
