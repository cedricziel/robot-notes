import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/knowledge/proposal_review_panel.dart';
import 'package:app/src/theme/app_theme.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class _ReviewServer {
  int revision = 4;
  bool conflict = false;
  bool invalidBlocks = false;
  bool missingTarget = false;
  int baseVersion = 2;
  List<Map<String, dynamic>>? operations;
  List<String> actions = ['read', 'comment', 'approve', 'request_changes'];
  final List<Map<String, dynamic>> comments = [];
  Map<String, dynamic>? submission;
  Completer<void>? pendingSubmission;

  final summary = <String, dynamic>{
    'note_id': 'n',
    'proposal_id': 'p',
    'new_note': true,
    'title': 'Team knowledge',
    'state': 'pending',
    'author_label': 'Agent',
  };

  late final api = RobotNotesClient(
    config: const AppConfig(
      baseUrl: 'https://notes.example',
      apiKey: 'test',
      actor: 'Reviewer',
    ),
    httpClient: MockClient((request) async {
      if (request.method == 'POST') {
        submission = jsonDecode(request.body) as Map<String, dynamic>;
        await pendingSubmission?.future;
        if (conflict) {
          conflict = false;
          revision++;
          return http.Response('{"error":"proposal_version_conflict"}', 409);
        }
        if (request.url.path.endsWith('/comments')) {
          comments.add({
            'author_label': 'Reviewer',
            'body': submission!['body'],
          });
        }
        revision++;
        return http.Response('{}', 200);
      }
      if (request.url.path == '/notes/n') {
        return http.Response(
          jsonEncode({
            'id': 'n',
            'title': 'Team knowledge',
            'content': 'Accepted text',
            'version': 2,
            'created_at': '2026-10-13T00:00:00Z',
            'updated_at': '2026-10-13T00:00:00Z',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/blocks')) {
        return http.Response(
          jsonEncode({
            'version': 2,
            'offset_encoding': 'utf-16',
            'content_hash': invalidBlocks
                ? 'wrong'
                : sha256.convert(utf8.encode('Accepted text')).toString(),
            'blocks': [
              {
                'id': 'b',
                'revision': 2,
                'start': 0,
                'end': 13,
                'hash': sha256.convert(utf8.encode('Accepted text')).toString(),
              },
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          ...summary,
          'new_note': !invalidBlocks && !missingTarget && operations == null,
          'base_version': baseVersion,
          'record_revision': revision,
          'allowed_actions': actions,
          'draft': {'content': 'Proposed text'},
          'comments': comments,
          if (operations != null) 'operations': operations,
          if (missingTarget)
            'operations': [
              {'type': 'replace', 'block_id': 'missing', 'text': 'Replacement'},
            ],
        }),
        200,
      );
    }),
  );

  Widget build({
    TargetPlatform platform = TargetPlatform.android,
    bool dark = false,
    double textScale = 1,
  }) => MaterialApp(
    theme: dark
        ? AppTheme.dark(platform: platform)
        : AppTheme.light(platform: platform),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: ProposalReviewPanel(
        api: api,
        summary: summary,
        onChanged: (_) async {},
        onBusyChanged: (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('stale block revision prevents approval despite valid hashes', (
    tester,
  ) async {
    final server = _ReviewServer()
      ..operations = [
        {
          'type': 'replace',
          'block_id': 'b',
          'expected_revision': 1,
          'text': 'Replacement',
        },
      ];
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The accepted target changed. Update the proposal before reviewing.',
      ),
      findsOneWidget,
    );
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets(
    'note deletion compares proposal base version with accepted note',
    (tester) async {
      final server = _ReviewServer()
        ..baseVersion = 1
        ..operations = [
          {'type': 'delete_note'},
        ];
      await tester.pumpWidget(server.build());
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The accepted target changed. Update the proposal before reviewing.',
        ),
        findsOneWidget,
      );
      expect(find.text('Approve'), findsNothing);
    },
  );

  testWidgets(
    'matching block revision permits review after an unrelated note update',
    (tester) async {
      final server = _ReviewServer()
        ..baseVersion = 1
        ..operations = [
          {
            'type': 'replace',
            'block_id': 'b',
            'expected_revision': 2,
            'text': 'Replacement',
          },
        ];
      await tester.pumpWidget(server.build());
      await tester.pumpAndSettle();
      expect(find.text('Accepted text'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
    },
  );

  testWidgets('posting a comment refreshes discussion in the same review', (
    tester,
  ) async {
    final server = _ReviewServer();
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Source verified');
    await tester.pump();
    await tester.ensureVisible(find.text('Post comment'));
    await tester.tap(find.text('Post comment'));
    await tester.pumpAndSettle();
    expect(server.submission, {
      'record_revision': 4,
      'body': 'Source verified',
    });
    expect(find.text('Source verified'), findsOneWidget);
    expect(find.text('Team knowledge'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('conflict refreshes revision and retains the inline draft', (
    tester,
  ) async {
    final server = _ReviewServer()..conflict = true;
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Please check the source');
    await tester.pump();
    await tester.ensureVisible(find.text('Request changes'));
    await tester.tap(find.text('Request changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Review the refreshed changes'), findsOneWidget);
    expect(find.text('Please check the source'), findsOneWidget);
    await tester.ensureVisible(find.text('Request changes'));
    await tester.tap(find.text('Request changes'));
    await tester.pumpAndSettle();
    expect(server.submission, {
      'record_revision': 5,
      'decision': 'request_changes',
      'comment': 'Please check the source',
    });
  });

  testWidgets('unverified accepted content prevents decisions', (tester) async {
    final server = _ReviewServer()..invalidBlocks = true;
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    expect(
      find.text('Accepted content changed. Refresh before reviewing.'),
      findsOneWidget,
    );
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('read-only proposal omits the composer and decisions', (
    tester,
  ) async {
    final server = _ReviewServer()..actions = ['read'];
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    expect(find.text('Proposed text'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Approve'), findsNothing);
  });
  testWidgets(
    'missing accepted target prevents approving an unseen replacement',
    (tester) async {
      final server = _ReviewServer()..missingTarget = true;
      await tester.pumpWidget(server.build());
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The accepted target is unavailable. Refresh before reviewing.',
        ),
        findsOneWidget,
      );
      expect(find.text('Approve'), findsNothing);
    },
  );

  testWidgets(
    'phone review wraps actions with larger text in Apple dark theme',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = _ReviewServer();
      await tester.pumpWidget(
        server.build(platform: TargetPlatform.iOS, dark: true, textScale: 1.8),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Post comment'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pending decision disables duplicate actions', (tester) async {
    final server = _ReviewServer()..pendingSubmission = Completer<void>();
    await tester.pumpWidget(server.build());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve'));
    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve'))
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    server.pendingSubmission!.complete();
    await tester.pumpAndSettle();
  });
}
