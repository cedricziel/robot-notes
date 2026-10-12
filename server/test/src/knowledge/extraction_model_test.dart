import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:test/test.dart';

void main() {
  test(
      'compatible adapter uses configured destination and '
      'requests bounded JSON', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://model.example/v1/chat/completions',
      );
      expect(request.headers['authorization'], 'Bearer fixture-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'chosen-model');
      expect(body['response_format'], {'type': 'json_object'});
      expect(body['max_completion_tokens'], 4096);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"findings": []}'},
            }
          ],
        }),
        200,
      );
    });
    final model = OpenAiCompatibleKnowledgeExtractor(
      KnowledgeExtractionConfig(
        endpoint: Uri.parse('https://model.example/v1'),
        model: 'chosen-model',
        apiKey: 'fixture-key',
      ),
      client: client,
    );
    final result = await model.extract(
      const KnowledgeExtractionInput(
        text: 'Confirmed fact.',
        start: 0,
        end: 15,
        accepted: [],
        pending: [],
        types: [],
      ),
    );
    expect(result, isEmpty);
    model.close();
    client.close();
  });
  test('credentials do not change configuration identity', () {
    final first = KnowledgeExtractionConfig(
      endpoint: Uri.parse('http://localhost:8000/v1'),
      model: 'local',
      apiKey: 'first',
    );
    final rotated = KnowledgeExtractionConfig(
      endpoint: first.endpoint,
      model: first.model,
      apiKey: 'rotated',
    );
    expect(first.fingerprint, rotated.fingerprint);
  });

  test('provider failures expose safe categories and bounded retry eligibility',
      () async {
    for (final status in [401, 429, 503]) {
      final client =
          MockClient((_) async => http.Response('provider-secret', status));
      final model = OpenAiCompatibleKnowledgeExtractor(
        KnowledgeExtractionConfig(
          endpoint: Uri.parse('https://fixture.invalid/v1'),
          model: 'fixture',
          apiKey: 'server-secret',
        ),
        client: client,
      );
      try {
        await expectLater(
          model.extract(
            const KnowledgeExtractionInput(
              text: 'Source.',
              start: 0,
              end: 7,
              accepted: [],
              pending: [],
              types: [],
            ),
          ),
          throwsA(
            isA<KnowledgeExtractionFailure>()
                .having((error) => error.transient, 'transient', status != 401)
                .having(
                  (error) => error.code,
                  'safe category',
                  status == 401 ? 'model_request' : 'model_transient',
                ),
          ),
        );
      } finally {
        model.close();
        client.close();
      }
    }
  });
}
