import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How the note view adapts to Apple platforms: chevron back button, an
/// iOS action sheet behind the "more" button, and Cupertino dialogs.
const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _noteJson({String path = ''}) => <String, Object?>{
  'id': '01H',
  'title': 'hello',
  'content': 'world',
  'version': 1,
  'path': path,
  'created_at': _now,
  'updated_at': _now,
  'tags': <String>[],
};

Future<List<String>> _pumpViewer(
  WidgetTester tester, {
  required TargetPlatform platform,
  NotePresentation presentation = NotePresentation.page,
}) async {
  final calls = <String>[];
  final mock = MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    if (request.method == 'GET' && request.url.path == '/notes/01H') {
      return http.Response(jsonEncode(_noteJson()), 200);
    }
    if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
      return http.Response('', 204);
    }
    if (request.method == 'PUT' && request.url.path == '/notes/01H') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(_noteJson(path: body['path'] as String)),
        200,
      );
    }
    return http.Response('unexpected', 500);
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
  addTearDown(ctrl.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(platform: platform),
      home: NoteScreen(
        controller: ctrl,
        presentation: presentation,
        onClose: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  group('leading button', () {
    testWidgets('is a chevron on iOS', (tester) async {
      await _pumpViewer(tester, platform: TargetPlatform.iOS);

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect((button.icon as Icon).icon, Icons.arrow_back_ios);
    });

    testWidgets('is a chevron on macOS', (tester) async {
      await _pumpViewer(tester, platform: TargetPlatform.macOS);

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect((button.icon as Icon).icon, Icons.arrow_back_ios);
    });

    testWidgets('stays an arrow on Android', (tester) async {
      await _pumpViewer(tester, platform: TargetPlatform.android);

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect((button.icon as Icon).icon, Icons.arrow_back);
    });

    testWidgets('is still a close icon for the pane on iOS', (tester) async {
      await _pumpViewer(
        tester,
        platform: TargetPlatform.iOS,
        presentation: NotePresentation.pane,
      );

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect((button.icon as Icon).icon, Icons.close);
    });
  });

  group('more menu', () {
    testWidgets('on iOS is an action sheet with a destructive Delete', (
      tester,
    ) async {
      final calls = await _pumpViewer(tester, platform: TargetPlatform.iOS);

      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.byType(PopupMenuButton<void>), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
      final delete = tester.widget<CupertinoActionSheetAction>(
        find.byKey(const Key('note.delete')),
      );
      expect(delete.isDestructiveAction, isTrue);

      await tester.tap(find.byKey(const Key('note.delete')));
      await tester.pumpAndSettle();

      // The sheet is gone and the Cupertino confirmation is up.
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('Delete this note?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('note.delete.confirm')));
      await tester.pumpAndSettle();
      expect(calls, contains('DELETE /notes/01H'));
    });

    testWidgets('on iOS, Cancel dismisses the sheet without acting', (
      tester,
    ) async {
      final calls = await _pumpViewer(tester, platform: TargetPlatform.iOS);

      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.text('Delete this note?'), findsNothing);
      expect(calls, isNot(contains('DELETE /notes/01H')));
    });

    testWidgets('on iOS, Move opens the Cupertino move dialog', (tester) async {
      final calls = await _pumpViewer(tester, platform: TargetPlatform.iOS);

      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.move')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('note.move.input')),
        'Projects',
      );
      await tester.tap(find.byKey(const Key('note.move.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('PUT /notes/01H'));
    });

    testWidgets('on macOS stays a popup menu, not a sheet', (tester) async {
      await _pumpViewer(tester, platform: TargetPlatform.macOS);

      expect(find.byType(PopupMenuButton<void>), findsOneWidget);
      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.byKey(const Key('note.delete')), findsOneWidget);
    });
  });
}
