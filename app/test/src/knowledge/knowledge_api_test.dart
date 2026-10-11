import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/api/api_exceptions.dart';
import 'package:app/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const config = AppConfig(
    baseUrl: 'https://notes.example',
    apiKey: 'key',
    actor: 'reviewer',
  );
  test(
    'proposal decisions preserve record revision and authenticated vault',
    () async {
      final client = RobotNotesClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/notes/n/proposals/p/decisions');
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer key');
          expect(jsonDecode(request.body), {
            'decision': 'approve',
            'record_revision': 7,
          });
          return http.Response('{"state":"accepted"}', 200);
        }),
      );
      expect(
        (await client.decideKnowledgeProposal(
          'n',
          'p',
          decision: 'approve',
          recordRevision: 7,
        ))['state'],
        'accepted',
      );
    },
  );
  test('forbidden review remains permission failure', () async {
    final client = RobotNotesClient(
      config: config,
      httpClient: MockClient(
        (_) async =>
            http.Response('{"message":"Review permission required"}', 403),
      ),
    );
    await expectLater(
      client.getKnowledgePermissions('n'),
      throwsA(isA<ForbiddenException>()),
    );
  });
  test(
    'stale review returns conflict without interpreting proposal as note',
    () async {
      final client = RobotNotesClient(
        config: config,
        httpClient: MockClient(
          (_) async => http.Response(
            '{"error":"proposal_version_conflict","current_record_revision":9}',
            409,
          ),
        ),
      );
      await expectLater(
        client.decideKnowledgeProposal(
          'n',
          'p',
          decision: 'approve',
          recordRevision: 7,
        ),
        throwsA(isA<KnowledgeConflictException>()),
      );
    },
  );
}
