import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../knowledge_test_context.dart' as knowledge_fixture;
import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  late String id;
  knowledge_fixture.authorizedSetUp(() async {
    app = await TestApp.start();
    final note = await app.deps.noteWriteService.create(
      title: 'Blocks',
      content: '# Title\n\noriginal\n\n# End',
      actor: 'tester',
      properties: {'history': true},
    );
    id = note.id;
    await app.deps.noteWriteService.update(
      id: id,
      title: note.title,
      content: '# Title\n\nupdated\n\n# End',
      actor: 'tester',
      ifMatch: 1,
    );
  });
  tearDown(() => app.close());

  knowledge_fixture.authorizedTest(
      'returns accepted current and historical identities', () async {
    final current = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: app.headers(),
    );
    final historical = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks?version=1'),
      headers: app.headers(),
    );

    expect(current.statusCode, 200, reason: current.body);
    expect(historical.statusCode, 200, reason: historical.body);
    final map = jsonDecode(current.body) as Map<String, dynamic>;
    final old = jsonDecode(historical.body) as Map<String, dynamic>;
    expect(map['version'], 2);
    expect(map['offset_encoding'], 'utf-16');
    final blocks =
        (map['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    final prior = (old['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(blocks.map((b) => b['id']), prior.map((b) => b['id']));
    expect(blocks[1]['revision'], 2);
  });

  knowledge_fixture.authorizedTest(
      'requires authentication and an authorized vault', () async {
    final anonymous = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
    );
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:read',
      resource: app.baseUrl,
    );
    final headers = {'Authorization': 'Bearer ${grant.accessToken}'};
    final denied = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: {...headers, 'X-Vault-Id': 'another-vault'},
    );
    final readable = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: headers,
    );

    expect(anonymous.statusCode, 401);
    expect(denied.statusCode, 403);
    expect(readable.statusCode, 200);
  });

  knowledge_fixture.authorizedTest(
      'write scope alone cannot inspect block history', () async {
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:write',
      resource: app.baseUrl,
    );

    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks?version=1'),
      headers: {'Authorization': 'Bearer ${grant.accessToken}'},
    );

    expect(response.statusCode, 403);
  });

  knowledge_fixture.authorizedTest(
      'reports unavailable metadata for an ordinary legacy note to readers',
      () async {
    final legacy = await app.deps.noteWriteService.create(
      title: 'Legacy',
      content: 'ordinary',
      actor: 'tester',
    );
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:read',
      resource: app.baseUrl,
    );

    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/${legacy.id}/blocks'),
      headers: {'Authorization': 'Bearer ${grant.accessToken}'},
    );

    expect(response.statusCode, 409);
    expect(jsonDecode(response.body), {'error': 'block_map_unavailable'});
  });

  knowledge_fixture.authorizedTest(
      'captures a baseline map for proposers on an ordinary note', () async {
    final legacy = await app.deps.noteWriteService.create(
      title: 'Legacy',
      content: 'ordinary',
      actor: 'tester',
    );

    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/${legacy.id}/blocks'),
      headers: app.headers(),
    );

    expect(response.statusCode, 200, reason: response.body);
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    expect(map['version'], legacy.version);
    expect(map['blocks'], hasLength(1));
    final current = await app.deps.storage.read(legacy.id);
    expect(current.version, legacy.version);
    expect(current.content, 'ordinary');
  });

  knowledge_fixture.authorizedTest(
      'reports stale metadata after an external canonical rewrite', () async {
    final file = File('${app.deps.storage.contentDir.path}/Blocks.md');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('\nupdated\n', '\nexternal\n'),
    );

    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: app.headers(),
    );

    expect(response.statusCode, 409);
    expect(jsonDecode(response.body), {'error': 'block_map_stale'});
  });

  knowledge_fixture.authorizedTest('rejects an invalid accepted revision query',
      () async {
    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks?version=0'),
      headers: app.headers(),
    );

    expect(response.statusCode, 400);
  });

  knowledge_fixture
      .authorizedTest('reports a missing retained accepted revision', () async {
    final response = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks?version=99'),
      headers: app.headers(),
    );

    expect(response.statusCode, 404);
  });
}
