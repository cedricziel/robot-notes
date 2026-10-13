import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

import '../src/knowledge/type_definition_test.dart' show definition;
import '_test_app.dart';

void main() {
  test(
      'configured HTTP model extracts pending knowledge and a '
      'human publishes it', () async {
    final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    model.listen((request) async {
      requests++;
      final raw = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final messages = raw['messages'] as List<dynamic>;
      final input = jsonDecode(
        (messages.last as Map<String, dynamic>)['content'] as String,
      ) as Map<String, dynamic>;
      final source = input['source'] as String;
      const statement = 'Agent credentials require scoped permissions.';
      final utf16Start = source.indexOf(statement);
      final start = source.substring(0, utf16Start).runes.length +
          (input['source_start'] as int);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'findings': [
                    {
                      'dispositions': ['new'],
                      'reason': 'User-confirmed durable fact',
                      'title': 'Agent credentials',
                      'type_id': 'urn:robot-notes:type:Claim',
                      'statement': statement,
                      'source_quote': statement,
                      'locator': {
                        'kind': 'text_range',
                        'start': start,
                        'end': start + statement.runes.length,
                      },
                    }
                  ],
                }),
              },
            }
          ],
        }),
      );
      await request.response.close();
    });
    final app = await TestApp.start(
      knowledgeEnabled: true,
      extractionConfig: KnowledgeExtractionConfig(
        endpoint: Uri.parse('http://127.0.0.1:${model.port}/v1'),
        model: 'fixture-model',
        apiKey: 'fixture-model-key',
      ),
    );
    try {
      await withKnowledgePrincipal(const KnowledgePrincipal.operator(),
          () async {
        final claim = definition(
          'urn:robot-notes:type:Claim',
          properties: {
            'statement': {'value_type': 'text', 'required': true},
          },
        );
        (claim['definition']! as Map<String, Object?>)['relations'] = {
          'supported_by': {
            'target_types': [
              {'id': 'urn:robot-notes:type:Evidence', 'version': 1},
            ],
            'min_items': 1,
          },
        };
        await app.deps.knowledge.types.accept(
          {
            'claim.md': serializeFrontmatter(
              Frontmatter(metadata: {'knowledge': claim}, body: ''),
            ),
            'evidence.md': serializeFrontmatter(
              Frontmatter(
                metadata: {
                  'knowledge': definition('urn:robot-notes:type:Evidence'),
                },
                body: '',
              ),
            ),
          },
          expectedGeneration: 0,
        );
      });
      Future<http.Response> operation(String name, Map<String, Object?> body) =>
          http.post(
            Uri.parse('${app.baseUrl}/knowledge/operations/$name'),
            headers: app.headers(),
            body: jsonEncode(body),
          );
      final configured = await operation('configure_source_scope', {
        'scope_id': 'scope',
        'capture_adapters': ['hermes'],
        'principals': ['*'],
        'extraction_enabled': true,
        'trigger': 'both',
      });
      expect(configured.statusCode, 200, reason: configured.body);
      final captured = await operation('ingest_source', {
        'scope_id': 'scope',
        'adapter': 'hermes',
        'event_id': 'turn-1',
        'content_base64': base64Encode(
          utf8.encode(
            jsonEncode({
              'messages': [
                {
                  'role': 'user',
                  'content': 'Agent credentials require scoped permissions.',
                },
                {'role': 'assistant', 'content': 'Recorded.'},
              ],
            }),
          ),
        ),
        'media_type': 'application/json',
        'automatic': true,
        'observation_kind': 'completed_turn',
        'conversation_id': 'conversation',
      });
      expect(captured.statusCode, 200, reason: captured.body);
      await app.deps.knowledge.worker!.runOnce();
      expect(requests, 1);
      final health = await operation('extraction_health', {});
      final jobs = (jsonDecode(health.body) as Map<String, dynamic>)['jobs']
          as List<dynamic>;
      expect(
        (jobs.single as Map<String, dynamic>)['state'],
        'completed',
        reason: health.body,
      );
      final before = await operation('query_knowledge', {});
      expect(
        (jsonDecode(before.body) as Map<String, dynamic>)['items'],
        isEmpty,
      );
      final records = await app.deps.storage.proposalRecords();
      final proposal = records.single;
      final reviewed = await operation(
        'review_knowledge_proposal',
        {'proposal_id': proposal.id, 'record_revision': 1},
      );
      expect(reviewed.statusCode, 200, reason: reviewed.body);
      final after = await operation('query_knowledge', {});
      expect(
        (jsonDecode(after.body) as Map<String, dynamic>)['items'],
        hasLength(2),
      );
    } finally {
      await app.close();
      await model.close(force: true);
    }
  });
}
