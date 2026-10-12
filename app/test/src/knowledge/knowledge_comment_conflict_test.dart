import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/knowledge/knowledge_review_screen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared/shared.dart';

void main() {
  testWidgets(
    'concurrent block comment refreshes revision before resubmission',
    (tester) async {
      const content = 'Accepted truth';
      final rawNote = {
        'id': 'n',
        'title': 'Knowledge',
        'content': content,
        'version': 1,
        'created_at': '2026-10-11T00:00:00Z',
        'updated_at': '2026-10-11T00:00:00Z',
      };
      var revision = 1;
      final submittedRevisions = <int>[];
      final comments = <Map<String, Object?>>[];
      final api = RobotNotesClient(
        config: const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'test',
          actor: 'human',
        ),
        httpClient: MockClient((request) async {
          Object body = {};
          switch (request.url.path) {
            case '/notes/n':
              body = rawNote;
            case '/notes/n/permissions':
              body = {
                'allowed_actions': ['read', 'propose'],
              };
            case '/notes/n/blocks':
              body = {
                'version': 1,
                'content_hash': sha256.convert(utf8.encode(content)).toString(),
                'offset_encoding': 'utf-16',
                'blocks': [
                  {
                    'id': 'b',
                    'revision': 1,
                    'start': 0,
                    'end': content.length,
                    'hash': sha256.convert(utf8.encode(content)).toString(),
                  },
                ],
              };
            case '/notes/n/proposals':
              body = {'items': <Object?>[]};
            case '/notes/n/history':
              body = {'revisions': <Object?>[]};
            case '/notes/n/comments':
              if (request.method == 'POST') {
                final input = jsonDecode(request.body) as Map<String, dynamic>;
                submittedRevisions.add(input['record_revision'] as int);
                if (submittedRevisions.length == 1) {
                  revision = 2;
                  comments.add({
                    'block_id': 'b',
                    'body': 'Concurrent comment',
                    'author_label': 'Another reviewer',
                  });
                  return http.Response('{"error":"comments_changed"}', 409);
                }
                comments.add({'block_id': 'b', 'body': input['body']});
                revision++;
              }
              body = {'items': comments, 'record_revision': revision};
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: KnowledgeReviewScreen(
            api: api,
            note: Note.fromJson(rawNote),
            onAcceptedChange: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blocks and comments'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'My comment');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(submittedRevisions, [1]);
      expect(find.textContaining('Concurrent comment'), findsOneWidget);
      expect(find.textContaining('This review changed.'), findsOneWidget);

      await tester.tap(find.text('Comment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'My comment');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(submittedRevisions, [1, 2]);
      expect(find.textContaining('My comment'), findsOneWidget);
    },
  );
}
