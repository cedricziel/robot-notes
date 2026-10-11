import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  late String id;
  late Map<String, String> agent;
  late Map<String, String> human;
  setUp(() async {
    app = await TestApp.start();
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({
        'title': 'A',
        'path': 'team',
        'content': 'first\r\n\r\nlast',
      }),
    );
    expect(created.statusCode, 201, reason: created.body);
    id = (jsonDecode(created.body) as Map)['id'] as String;
    await app.deps.authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'team',
      KnowledgePolicyPatch(curated: true),
    );
    final issued = await app.deps.agentCredentials.issue(
      actor: 'Robot',
      scopes: {'notes:read', 'knowledge:propose'},
    );
    agent = {
      'Authorization': 'Bearer ${issued.secret}',
      'Content-Type': 'application/json',
    };
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      actor: 'Reviewer',
      scope: 'notes:read knowledge:review',
      resource: app.baseUrl,
    );
    human = {
      'Authorization': 'Bearer ${grant.accessToken}',
      'Content-Type': 'application/json',
    };
  });
  tearDown(() => app.close());

  Future<Map<String, dynamic>> propose({
    String key = 'one',
    String text = 'proposed\r\n',
  }) async {
    final blocks = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: agent,
    );
    expect(blocks.statusCode, 200, reason: blocks.body);
    final map = jsonDecode(blocks.body) as Map;
    final block = (map['blocks'] as List).first as Map;
    final response = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/proposals'),
      headers: agent,
      body: jsonEncode({
        'base_version': map['version'],
        'idempotency_key': key,
        'operations': [
          {
            'type': 'replace',
            'block_id': block['id'],
            'expected_revision': block['revision'],
            'text': text,
          }
        ],
      }),
    );
    expect(response.statusCode, 201, reason: response.body);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<http.Response> decision(
    Map<String, dynamic> proposal,
    String value, {
    Map<String, String>? headers,
  }) =>
      http.post(
        Uri.parse(
          '${app.baseUrl}/notes/${proposal['note_id']}/proposals/${proposal['proposal_id']}/decisions',
        ),
        headers: headers ?? human,
        body: jsonEncode({
          'decision': value,
          'record_revision': proposal['record_revision'],
        }),
      );

  test('propose-only agent and review-only human use the real HTTP pipeline',
      () async {
    final proposal = await propose();
    expect(proposal['accepted'], isFalse);
    expect((await app.deps.storage.read(id)).content, 'first\r\n\r\nlast');
    expect(await app.deps.searchIndex.search('proposed'), isEmpty);
    final accepted = await decision(proposal, 'approve');
    expect(accepted.statusCode, 200, reason: accepted.body);
    expect((jsonDecode(accepted.body) as Map)['accepted'], isTrue);
    expect((await app.deps.storage.read(id)).content, 'proposed\r\n\r\nlast');
    expect((await app.deps.searchIndex.search('proposed')).single.id, id);
    final repeated = await decision(proposal, 'approve');
    expect(repeated.statusCode, 409);
    expect((await app.deps.storage.read(id)).version, 2);
  });

  test('terminal state filters reach both vault and note index services',
      () async {
    final accepted = await propose();
    expect((await decision(accepted, 'approve')).statusCode, 200);
    final denied = await propose(key: 'denied', text: 'denied\r\n');
    expect((await decision(denied, 'deny')).statusCode, 200);
    for (final prefix in ['/notes/proposals', '/notes/$id/proposals']) {
      for (final state in ['accepted', 'denied']) {
        final response = await http.get(
          Uri.parse('${app.baseUrl}$prefix?state=$state'),
          headers: human,
        );
        expect(response.statusCode, 200, reason: response.body);
        final items = (jsonDecode(response.body) as Map)['items'] as List;
        expect(items, hasLength(1));
        expect((items.single as Map)['state'], state);
      }
    }
    final invalid = await http.get(
      Uri.parse('${app.baseUrl}/notes/proposals?state=invented'),
      headers: human,
    );
    expect(invalid.statusCode, 400);
  });

  test('draft is globally discoverable and reviewable without a placeholder',
      () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes/proposals'),
      headers: agent,
      body: jsonEncode({
        'path': 'team',
        'title': 'Draft',
        'content': 'draftsecret',
        'idempotency_key': 'draft',
      }),
    );
    expect(created.statusCode, 201, reason: created.body);
    final proposal = jsonDecode(created.body) as Map<String, dynamic>;
    final noteId = proposal['note_id'] as String;
    final missing = await http.get(
      Uri.parse('${app.baseUrl}/notes/$noteId'),
      headers: human,
    );
    expect(missing.statusCode, 404);
    final index = await http.get(
      Uri.parse('${app.baseUrl}/notes/proposals'),
      headers: human,
    );
    final summary =
        ((jsonDecode(index.body) as Map)['items'] as List).single as Map;
    expect(summary['new_note'], isTrue);
    expect(summary['title'], 'Draft');
    final detail = await http.get(
      Uri.parse(
        '${app.baseUrl}/notes/$noteId/proposals/${proposal['proposal_id']}',
      ),
      headers: human,
    );
    expect(detail.statusCode, 200, reason: detail.body);
    final inspected = jsonDecode(detail.body) as Map;
    expect((inspected['draft'] as Map)['content'], 'draftsecret');
    expect(inspected['allowed_actions'], contains('approve'));
    expect((await decision(proposal, 'approve')).statusCode, 200);
    final blocks = await http
        .get(Uri.parse('${app.baseUrl}/notes/$noteId/blocks'), headers: human);
    final map = jsonDecode(blocks.body) as Map;
    expect(map['content'], 'draftsecret');
    final block = (map['blocks'] as List).single as Map;
    expect(
      ((map['provenance'] as Map)[block['id']] as Map)['source_unknown'],
      isTrue,
    );
    await app.deps.storage.purgeHistory(noteId);
    expect(
      (await app.deps.storage.readBlockMap(noteId)).blocks.single.id,
      block['id'],
    );
    expect(await app.deps.storage.proposalRecords(noteId: noteId), isEmpty);
  });

  test('marked operator cannot acquire human review through HTTP rebinding',
      () async {
    final proposal = await propose();
    final response = await decision(
      proposal,
      'approve',
      headers: {
        ...app.headers(actor: 'Human label'),
        'X-Robot-Notes-Agent': ' TRUE ',
      },
    );
    expect(response.statusCode, 403, reason: response.body);
    expect((await app.deps.storage.read(id)).version, 1);
  });

  test('standalone comments need no proposal and follow block revision CAS',
      () async {
    final blocks = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks'),
      headers: human,
    );
    final block =
        ((jsonDecode(blocks.body) as Map)['blocks'] as List).first as Map;
    final comment = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/comments'),
      headers: human,
      body: jsonEncode({
        'record_revision': 0,
        'body': 'Why?',
        'block_id': block['id'],
        'block_revision': block['revision'],
      }),
    );
    expect(comment.statusCode, 200, reason: comment.body);
    expect(await app.deps.storage.proposalRecords(noteId: id), isEmpty);
    final stale = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/comments'),
      headers: human,
      body: jsonEncode({
        'record_revision': 0,
        'body': 'Old generation',
        'block_id': block['id'],
        'block_revision': block['revision'],
      }),
    );
    expect(stale.statusCode, 409);
  });
  test('tombstone blocks expose an empty map without prior text', () async {
    final response = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/proposals'),
      headers: agent,
      body: jsonEncode({
        'base_version': 1,
        'idempotency_key': 'delete',
        'operations': [
          {'type': 'delete_note'},
        ],
      }),
    );
    expect(response.statusCode, 201, reason: response.body);
    final proposal = jsonDecode(response.body) as Map<String, dynamic>;
    expect((await decision(proposal, 'approve')).statusCode, 200);
    final snapshot = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/blocks?version=2'),
      headers: human,
    );
    expect(snapshot.statusCode, 200, reason: snapshot.body);
    final map = jsonDecode(snapshot.body) as Map;
    expect(map['deleted'], isTrue);
    expect(map['content'], '');
    expect(map['blocks'], isEmpty);
    expect(map['provenance'], isEmpty);
  });
}
