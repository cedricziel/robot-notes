import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:app/src/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How the notes list adapts to Apple platforms: the iOS pull-to-refresh
/// control, Cupertino confirmation dialogs, and swipe-to-delete on touch
/// layouts.
const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _metaJson({required String id, String title = 'note'}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'version': 1,
      'path': '',
      'excerpt': '',
      'tags': <String>[],
      'created_at': _now,
      'updated_at': _now,
    };

http.Response _page(List<Object?> items) => http.Response(
  jsonEncode(<String, Object?>{
    'items': items,
    'limit': 50,
    'next_cursor': null,
  }),
  200,
);

/// Pumps the list on a phone-sized window under [platform]'s theme,
/// recording every request in the returned list.
Future<List<String>> _pumpPhoneList(
  WidgetTester tester, {
  required TargetPlatform platform,
  int deleteStatus = 204,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = <String>[];
  final mock = MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    if (request.url.path == '/notes') {
      return _page(<Object?>[_metaJson(id: '01H', title: 'swipe me')]);
    }
    if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
      return http.Response('', deleteStatus);
    }
    return http.Response('unexpected: ${request.url.path}', 500);
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final ctrl = NotesListController(api: api);
  addTearDown(ctrl.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(platform: platform),
      home: NotesListScreen(controller: ctrl),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

Future<void> _swipeAway(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const Key('notes.tile.01H')),
    const Offset(-400, 0),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('pull-to-refresh', () {
    testWidgets('is the Cupertino control on iOS', (tester) async {
      await _pumpPhoneList(tester, platform: TargetPlatform.iOS);

      // The control has no extent until pulled, so it counts as offstage.
      expect(
        find.byType(CupertinoSliverRefreshControl, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(RefreshIndicator), findsNothing);
    });

    testWidgets('is the Cupertino control on macOS', (tester) async {
      await _pumpPhoneList(tester, platform: TargetPlatform.macOS);

      // The control has no extent until pulled, so it counts as offstage.
      expect(
        find.byType(CupertinoSliverRefreshControl, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(RefreshIndicator), findsNothing);
    });

    testWidgets('stays the Material indicator on Android', (tester) async {
      await _pumpPhoneList(tester, platform: TargetPlatform.android);

      expect(
        find.byType(CupertinoSliverRefreshControl, skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('the Cupertino control re-fetches the first page', (
      tester,
    ) async {
      final calls = await _pumpPhoneList(tester, platform: TargetPlatform.iOS);
      expect(calls.where((c) => c == 'GET /notes'), hasLength(1));

      // Overscroll far past the trigger and let go.
      await tester.drag(
        find.byKey(const Key('notes.list')),
        const Offset(0, 300),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c == 'GET /notes'), hasLength(2));
    });
  });

  group('delete confirmation on iOS', () {
    testWidgets('is a Cupertino alert with a destructive Delete action', (
      tester,
    ) async {
      final calls = await _pumpPhoneList(tester, platform: TargetPlatform.iOS);

      await tester.longPress(find.byKey(const Key('notes.tile.01H')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.tile.01H.delete')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      final confirm = tester.widget<CupertinoDialogAction>(
        find.byKey(const Key('notes.delete.confirm')),
      );
      expect(confirm.isDestructiveAction, isTrue);
      expect(find.byType(FilledButton), findsNothing);

      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swipe me'), findsNothing);
    });
  });

  group('swipe to delete', () {
    testWidgets('swiping a row left asks, then deletes on confirm', (
      tester,
    ) async {
      final calls = await _pumpPhoneList(tester, platform: TargetPlatform.iOS);

      await _swipeAway(tester);
      expect(find.text('Delete this note?'), findsOneWidget);
      expect(calls, isNot(contains('DELETE /notes/01H')));

      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swipe me'), findsNothing);
      expect(find.text('Note deleted'), findsOneWidget);
    });

    testWidgets('cancelling the confirmation keeps the row', (tester) async {
      final calls = await _pumpPhoneList(tester, platform: TargetPlatform.iOS);

      await _swipeAway(tester);
      await tester.tap(find.byKey(const Key('notes.delete.cancel')));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(find.text('swipe me'), findsOneWidget);
      expect(find.byKey(const Key('notes.tile.01H')), findsOneWidget);
    });

    testWidgets('a failed delete springs the row back', (tester) async {
      final calls = await _pumpPhoneList(
        tester,
        platform: TargetPlatform.iOS,
        deleteStatus: 500,
      );

      await _swipeAway(tester);
      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swipe me'), findsOneWidget);
    });

    testWidgets('works the same on Android phones', (tester) async {
      final calls = await _pumpPhoneList(
        tester,
        platform: TargetPlatform.android,
      );

      await _swipeAway(tester);
      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swipe me'), findsNothing);
    });

    testWidgets('is off on a wide layout, where hover-delete exists', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient(
        (request) async =>
            _page(<Object?>[_metaJson(id: '01H', title: 'wide')]),
      );
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(platform: TargetPlatform.macOS),
          home: NotesListScreen(controller: ctrl),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Dismissible), findsNothing);
    });
  });

  testWidgets('the list has no private scroll controller, so it can be the '
      'primary scrollable (iOS status-bar tap scrolls to top)', (tester) async {
    await _pumpPhoneList(tester, platform: TargetPlatform.iOS);

    final scroll = tester.widget<CustomScrollView>(
      find.byKey(const Key('notes.list')),
    );
    expect(scroll.controller, isNull);
  });
}
