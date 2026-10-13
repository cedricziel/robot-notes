import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/knowledge/knowledge_proposals_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('new knowledge can be reviewed without an accepted placeholder', (
    tester,
  ) async {
    var acceptedReads = 0;
    var approved = false;
    final client = RobotNotesClient(
      config: const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'human',
        actor: 'Reviewer',
      ),
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/proposals') {
          return http.Response(
            jsonEncode({
              'items': approved
                  ? <Object?>[]
                  : [
                      {
                        'note_id': 'reserved',
                        'proposal_id': 'p',
                        'new_note': true,
                        'title': 'Proposed knowledge',
                        'path': 'Team',
                        'state': 'pending',
                        'author_label': 'Agent',
                      },
                    ],
            }),
            200,
          );
        }
        if (request.url.path == '/notes/reserved') {
          acceptedReads++;
          return http.Response('{}', 404);
        }
        if (request.url.path.endsWith('/decisions')) {
          expect(jsonDecode(request.body), {
            'decision': 'approve',
            'record_revision': 4,
          });
          approved = true;
          return http.Response('{"state":"accepted"}', 200);
        }
        return http.Response(
          jsonEncode({
            'proposal_id': 'p',
            'note_id': 'reserved',
            'new_note': true,
            'draft': {
              'title': 'Proposed knowledge',
              'content': 'Pending evidence-backed claim',
            },
            'author_label': 'Agent',
            'state': 'pending',
            'record_revision': 4,
            'allowed_actions': ['read', 'approve'],
            'operations': <Object?>[],
            'evidence_refs': <Object?>[],
            'comments': <Object?>[],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: KnowledgeProposalsScreen(api: client),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pending evidence-backed claim'), findsNothing);
    await tester.tap(find.text('Proposed knowledge'));
    await tester.pumpAndSettle();
    expect(find.text('Pending evidence-backed claim'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(approved, isTrue);
    expect(acceptedReads, 0);
    expect(find.text('No active proposals'), findsOneWidget);
  });
  for (final type in ['delete', 'replace', 'delete_note']) {
    testWidgets('inbox $type review shows verified accepted target', (
      tester,
    ) async {
      const original = 'Accepted original claim';
      final summary = {
        'note_id': 'n',
        'proposal_id': 'p',
        'new_note': false,
        'title': 'Existing knowledge',
        'path': 'Team',
        'state': 'pending',
        'author_label': 'Agent',
      };
      final client = RobotNotesClient(
        config: const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'human',
          actor: 'Reviewer',
        ),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          Object body = {};
          if (path == '/notes/proposals' || path == '/notes/n/proposals') {
            body = {
              'items': [summary],
            };
          }
          if (path == '/notes/n') {
            body = {
              'id': 'n',
              'title': 'Existing knowledge',
              'content': original,
              'version': 1,
              'created_at': '2026-10-12T00:00:00Z',
              'updated_at': '2026-10-12T00:00:00Z',
            };
          }
          if (path.endsWith('/permissions')) {
            body = {
              'curated': true,
              'allowed_actions': ['read', 'review'],
            };
          }
          if (path.endsWith('/blocks')) {
            body = {
              'version': 1,
              'offset_encoding': 'utf-16',
              'content_hash': sha256.convert(utf8.encode(original)).toString(),
              'blocks': [
                {
                  'id': 'b',
                  'revision': 1,
                  'start': 0,
                  'end': original.length,
                  'hash': sha256.convert(utf8.encode(original)).toString(),
                },
              ],
            };
          }
          if (path.endsWith('/comments')) {
            body = {'items': <Object?>[], 'record_revision': 0};
          }
          if (path.endsWith('/history')) body = {'revisions': <Object?>[]};
          if (path.endsWith('/proposals/p')) {
            body = {
              ...summary,
              'record_revision': 1,
              'allowed_actions': ['read', 'approve'],
              'operations': [
                {
                  'type': type,
                  if (type != 'delete_note') 'block_id': 'b',
                  if (type != 'delete_note') 'expected_revision': 1,
                  if (type == 'delete_note') 'expected_version': 1,
                  if (type == 'replace') 'text': 'Proposed replacement',
                },
              ],
              'evidence_refs': <Object?>[],
              'comments': <Object?>[],
            };
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: KnowledgeProposalsScreen(api: client),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Existing knowledge'));
      await tester.pumpAndSettle();
      expect(find.text(original), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
  testWidgets('inline comment survives resizing and a failed decision', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = RobotNotesClient(
      config: const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'human',
        actor: 'Reviewer',
      ),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/decisions')) {
          return http.Response(
            '{"error":"unavailable","message":"Try again later"}',
            503,
          );
        }
        final proposal = {
          'note_id': 'reserved',
          'proposal_id': 'p',
          'new_note': true,
          'title': 'Proposed knowledge',
          'state': 'pending',
          'record_revision': 4,
          'author_label': 'Agent',
          'draft': {'content': 'A proposed claim'},
          'allowed_actions': ['read', 'comment', 'request_changes', 'approve'],
        };
        return http.Response(
          jsonEncode(
            request.url.path == '/notes/proposals'
                ? {
                    'items': [proposal],
                  }
                : proposal,
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(home: KnowledgeProposalsScreen(api: client)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proposed knowledge'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Please verify the source');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.text('A proposed claim'), findsOneWidget);
    expect(find.text('Please verify the source'), findsOneWidget);
    await tester.ensureVisible(find.text('Request changes'));
    await tester.tap(find.text('Request changes'));
    await tester.pumpAndSettle();
    expect(find.text('Try again later'), findsOneWidget);
    expect(find.text('Please verify the source'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
