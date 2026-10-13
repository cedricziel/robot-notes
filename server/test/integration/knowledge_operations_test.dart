import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:server/src/frontmatter.dart';
import 'package:test/test.dart';

import '../src/knowledge/type_definition_test.dart' show definition;
import '_test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.start(knowledgeEnabled: true));
  tearDown(() async => app.close());

  Future<Map<String, dynamic>> operation(
    String name,
    Map<String, Object?> input, {
    Map<String, String>? headers,
    int status = 200,
  }) async {
    final response = await http.post(
      Uri.parse('${app.baseUrl}/knowledge/operations/$name'),
      headers: headers ?? app.headers(),
      body: jsonEncode(input),
    );
    expect(response.statusCode, status, reason: response.body);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  test(
      'HTTP type review and typed entry proposals preserve '
      'accepted-only queries', () async {
    final candidate = await operation('propose_knowledge_types', {
      'documents': {
        'person.md': serializeFrontmatter(
          Frontmatter(
            metadata: {
              'knowledge': definition(
                'urn:test:Person',
                properties: {
                  'name': {'value_type': 'text', 'required': true},
                },
              ),
            },
            body: 'Person guidance',
          ),
        ),
      },
      'idempotency_key': 'type-1',
    });
    expect((await operation('list_knowledge_types', {}))['items'], isEmpty);
    await operation(
      'review_knowledge_type_proposal',
      {'proposal_id': candidate['proposal_id'], 'record_revision': 1},
    );
    final credential = await app.deps.agentCredentials.issue(
      actor: 'writer',
      scopes: {
        'notes:read',
        'notes:write',
        'knowledge:propose',
        'knowledge:review',
      },
    );
    final headers = {
      'authorization': 'Bearer ${credential.secret}',
      'content-type': 'application/json',
    };
    final draft = await operation(
      'propose_knowledge',
      {
        'idempotency_key': 'person-1',
        'operations': [
          {
            'kind': 'create',
            'local_ref': 'person',
            'title': 'Ada',
            'properties': {'name': 'Ada'},
            'types': [
              {'id': 'urn:test:Person', 'version': 1},
            ],
          }
        ],
      },
      headers: headers,
    );
    expect((await operation('query_knowledge', {}))['items'], isEmpty);
    await operation(
      'review_knowledge_proposal',
      {'proposal_id': draft['proposal_id'], 'record_revision': 1},
      headers: headers,
      status: 403,
    );
    await operation(
      'review_knowledge_proposal',
      {'proposal_id': draft['proposal_id'], 'record_revision': 1},
    );
    final query = await operation('query_knowledge', {});
    expect(query['items'], hasLength(1));
    final note =
        (query['items'] as List<dynamic>).single as Map<String, dynamic>;
    final ordinary = await http.get(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: app.headers(),
    );
    expect(ordinary.statusCode, 200);
    expect((jsonDecode(ordinary.body) as Map<String, dynamic>)['title'], 'Ada');
    final denied = await http.delete(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: headers,
    );
    expect(denied.statusCode, 403);
  });

  test(
      'capture scope requires policy authority and never '
      'publishes raw source text', () async {
    await operation('configure_source_scope', {
      'scope_id': 'scope',
      'capture_adapters': ['hermes'],
      'principals': ['*'],
    });
    final source = await operation('ingest_source', {
      'scope_id': 'scope',
      'adapter': 'hermes',
      'event_id': 'turn-1',
      'content_base64': base64Encode(utf8.encode('Raw original material')),
      'media_type': 'text/plain',
      'automatic': true,
      'observation_kind': 'completed_turn',
    });
    expect(source['source'], containsPair('principal_id', 'operator'));
    expect((await operation('query_knowledge', {}))['items'], isEmpty);
    final notes = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
    );
    expect((jsonDecode(notes.body) as Map<String, dynamic>)['items'], isEmpty);
  });

  test('MCP advertises shared schemas and returns the same accepted type query',
      () async {
    final response = await http.post(
      Uri.parse('${app.baseUrl}/mcp'),
      headers: app.headers(),
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
    );
    expect(response.statusCode, 200, reason: response.body);
    final tools = ((jsonDecode(response.body) as Map<String, dynamic>)['result']
        as Map<String, dynamic>)['tools'] as List<dynamic>;
    expect(
      tools.where(
        (tool) => (tool as Map<String, dynamic>)['name'] == 'query_knowledge',
      ),
      hasLength(1),
    );
    final call = await http.post(
      Uri.parse('${app.baseUrl}/mcp'),
      headers: app.headers(),
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'list_knowledge_types',
          'arguments': <String, Object?>{},
        },
      }),
    );
    final result = (jsonDecode(call.body) as Map<String, dynamic>)['result']
        as Map<String, dynamic>;
    expect(
      (result['structuredContent'] as Map<String, dynamic>)['items'],
      isEmpty,
    );
  });
  test('original byte downloads preserve bytes and hide inaccessible sources',
      () async {
    await operation('configure_source_scope', {
      'scope_id': 'binary',
      'capture_adapters': ['upload'],
      'principals': ['operator'],
    });
    final bytes = [0, 255, 1, 2, 13, 10];
    final result = await operation('ingest_source', {
      'adapter': 'upload',
      'event_id': 'binary-1',
      'scope_id': 'binary',
      'content_base64': base64Encode(bytes),
      'media_type': 'application/octet-stream',
    });
    final source = result['source'] as Map<String, dynamic>;
    final inspected = await operation('inspect_source', {
      'source_id': source['id'],
      'source_revision': source['revision'],
    });
    final blob = inspected['blob_ref'] as Map<String, dynamic>;
    final url = Uri.parse('${app.baseUrl}${blob['url']}');
    final download = await http.get(url, headers: app.headers());
    expect(download.statusCode, 200);
    expect(download.bodyBytes, bytes);
    expect(download.headers['content-disposition'], contains('attachment'));
    final credential = await app.deps.agentCredentials.issue(
      actor: 'reader',
      scopes: {'notes:read'},
    );
    final headers = {'authorization': 'Bearer ${credential.secret}'};
    final hidden = await http.get(url, headers: headers);
    final missing = await http.get(
      Uri.parse(
        '${app.baseUrl}/knowledge/sources/missing/${source['revision']}',
      ),
      headers: headers,
    );
    expect(hidden.statusCode, 404);
    expect(missing.statusCode, hidden.statusCode);
    expect(missing.body, hidden.body);
    await operation('purge_source_revision', {
      'source_id': source['id'],
      'source_revision': source['revision'],
    });
    expect((await http.get(url, headers: app.headers())).statusCode, 404);
  });
}
