import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  late String id;
  setUp(() async {
    app = await TestApp.start();
    final note = await app.deps.noteWriteService.create(
      title: 'Historical note',
      content: 'originalknowledge',
      actor: 'tester',
      properties: {'history': true},
    );
    id = note.id;
    await app.deps.noteWriteService.update(
      id: id,
      title: note.title,
      content: 'replacementknowledge',
      ifMatch: 1,
      actor: 'tester',
    );
  });
  tearDown(() => app.close());

  test('restore updates accepted search and purge removes retained revisions',
      () async {
    final response = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: app.headers(),
      body: jsonEncode({'version': 1, 'if_match': 2}),
    );
    expect(response.statusCode, 200, reason: response.body);
    expect((jsonDecode(response.body) as Map<String, dynamic>)['version'], 3);
    expect(
      (await app.deps.searchIndex.search('originalknowledge')).single.id,
      id,
    );
    expect(await app.deps.searchIndex.search('replacementknowledge'), isEmpty);
    final purged = await http.delete(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: app.headers(),
    );
    expect(purged.statusCode, 204);
    expect(await app.deps.storage.revisions(id), isEmpty);
  });

  test('history requires authentication and authorized vault', () async {
    final anonymous =
        await http.get(Uri.parse('${app.baseUrl}/notes/$id/history'));
    expect(anonymous.statusCode, 401);
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:read',
      resource: app.baseUrl,
    );
    final headers = {
      'Authorization': 'Bearer ${grant.accessToken}',
      'Content-Type': 'application/json',
    };
    final denied = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: {...headers, 'X-Vault-Id': 'another-vault'},
    );
    expect(denied.statusCode, 403);
    final readable = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: headers,
    );
    expect(readable.statusCode, 200);
    final restore = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: headers,
      body: jsonEncode({'version': 1, 'if_match': 2}),
    );
    expect(restore.statusCode, 403);
  });

  test('ordinary writer cannot permanently purge history', () async {
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      scope: 'notes:read notes:write',
      resource: app.baseUrl,
    );
    final response = await http.delete(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: {'Authorization': 'Bearer ${grant.accessToken}'},
    );
    expect(response.statusCode, 403);
    expect((await app.deps.storage.revisions(id)).length, 2);
  });
  test('deleted restore conflict reports latest tombstone version', () async {
    await app.deps.noteWriteService.delete(id: id, actor: 'tester');
    final response = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: app.headers(),
      body: jsonEncode({'version': 1, 'if_match': 2}),
    );
    expect(response.statusCode, 409);
    expect(
      (jsonDecode(response.body) as Map<String, dynamic>)['current_version'],
      3,
    );
    final restored = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: app.headers(),
      body: jsonEncode({'version': 1, 'if_match': 3}),
    );
    expect(restored.statusCode, 200);
    expect((jsonDecode(restored.body) as Map<String, dynamic>)['version'], 4);
    expect(
      (await app.deps.searchIndex.search('originalknowledge')).single.id,
      id,
    );
  });
}
