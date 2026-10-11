import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/knowledge/knowledge_review_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

void main() {
  testWidgets(
    'pending content requires inspection and stale approval never retries',
    (tester) async {
      var decisions = 0;
      final rawNote = {
        'id': 'n',
        'title': 'Knowledge',
        'content': 'Accepted truth',
        'version': 1,
        'created_at': '2026-10-11T00:00:00Z',
        'updated_at': '2026-10-11T00:00:00Z',
      };
      final client = RobotNotesClient(
        config: const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'test',
          actor: 'human',
        ),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          Object body = {};
          if (path == '/notes/n') body = rawNote;
          if (path.endsWith('/permissions')) {
            body = {
              'curated': true,
              'allowed_actions': ['read', 'review'],
            };
          }
          if (path.endsWith('/blocks')) {
            body = {
              'version': 1,
              'content_hash': sha256
                  .convert(utf8.encode('Accepted truth'))
                  .toString(),
              'offset_encoding': 'utf-16',
              'provenance': {
                'b': {
                  'block_revision': 1,
                  'source_unknown': false,
                  'evidence_refs': [
                    {
                      'kind': 'note_revision',
                      'note_id': 'source',
                      'version': 2,
                    },
                  ],
                },
              },
              'blocks': [
                {
                  'id': 'b',
                  'revision': 1,
                  'start': 0,
                  'end': 14,
                  'hash': sha256
                      .convert(utf8.encode('Accepted truth'))
                      .toString(),
                },
              ],
            };
          }
          if (path.endsWith('/comments')) {
            body = {'items': <Object?>[], 'record_revision': 1};
          }
          if (path.endsWith('/history')) body = {'revisions': <Object?>[]};
          if (path.endsWith('/proposals')) {
            body = {
              'items': [
                {
                  'proposal_id': 'p',
                  'author_label': 'Agent',
                  'state': 'pending',
                },
              ],
            };
          }
          if (path.endsWith('/proposals/p')) {
            body = {
              'proposal_id': 'p',
              'author_label': 'Agent',
              'state': 'pending',
              'record_revision': 1,
              'allowed_actions': ['read', 'approve', 'deny', 'request_changes'],
              'operations': [
                {'type': 'replace', 'text': 'Pending claim'},
              ],
              'evidence_refs': <Object?>[],
              'comments': <Object?>[],
            };
          }
          if (path.endsWith('/decisions')) {
            decisions++;
            return http.Response('{"error":"proposal_version_conflict"}', 409);
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: KnowledgeReviewScreen(
            api: client,
            note: Note.fromJson(rawNote),
            onAcceptedChange: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pending claim'), findsNothing);
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      expect(find.text('Pending claim'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(decisions, 1);
      expect(
        find.textContaining('Inspect the refreshed proposal'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(decisions, 1);
      await tester.tap(find.text('Blocks and comments'));
      await tester.pumpAndSettle();
      expect(find.text('Accepted truth'), findsOneWidget);
      expect(find.text('Note source · version 2'), findsOneWidget);
      expect(find.text('Propose update'), findsNothing);
    },
  );
  testWidgets(
    'block replacement preserves its boundary before the next block',
    (tester) async {
      const content = 'First paragraph.\n\nNext paragraph.';
      const first = 'First paragraph.\n';
      Map<String, dynamic>? submitted;
      final rawNote = {
        'id': 'n',
        'title': 'Knowledge',
        'content': content,
        'version': 1,
        'created_at': '2026-10-11T00:00:00Z',
        'updated_at': '2026-10-11T00:00:00Z',
      };
      final client = RobotNotesClient(
        config: const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'test',
          actor: 'agent',
        ),
        httpClient: MockClient((request) async {
          Object body = {};
          final path = request.url.path;
          if (path == '/notes/n') body = rawNote;
          if (path.endsWith('/permissions')) {
            body = {
              'curated': true,
              'allowed_actions': ['read', 'propose'],
            };
          }
          if (path.endsWith('/blocks')) {
            body = {
              'version': 1,
              'content_hash': sha256.convert(utf8.encode(content)).toString(),
              'offset_encoding': 'utf-16',
              'blocks': [
                {
                  'id': 'b',
                  'revision': 1,
                  'start': 0,
                  'end': first.length,
                  'hash': sha256.convert(utf8.encode(first)).toString(),
                },
              ],
            };
          }
          if (path.endsWith('/comments')) {
            body = {'items': <Object?>[], 'record_revision': 1};
          }
          if (path.endsWith('/history')) body = {'revisions': <Object?>[]};
          if (path.endsWith('/proposals')) {
            if (request.method == 'POST') {
              submitted = jsonDecode(request.body) as Map<String, dynamic>;
            }
            body = {'items': <Object?>[]};
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: KnowledgeReviewScreen(
            api: client,
            note: Note.fromJson(rawNote),
            onAcceptedChange: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blocks and comments'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Propose update'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Updated paragraph.');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(
        (submitted?['operations'] as List).single['text'],
        'Updated paragraph.\n',
      );
      expect((submitted?['operations'] as List).single['expected_revision'], 1);
    },
  );
}
