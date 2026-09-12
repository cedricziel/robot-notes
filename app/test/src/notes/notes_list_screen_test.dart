import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _metaJson({
  required String id,
  String title = 'note',
  int version = 1,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'version': version,
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

void main() {
  testWidgets('initial render fetches the first page', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[
        _metaJson(id: '01H', title: 'hello'),
        _metaJson(id: '02H', title: 'world'),
      ]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    // Post-frame callback runs on the next pump; let it complete.
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('world'), findsOneWidget);
  });

  testWidgets('tapping a note tile invokes onNoteTap with the id',
      (tester) async {
    final mock = MockClient((request) async {
      return _page(<Object?>[_metaJson(id: '01H', title: 'tap me')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    String? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          onNoteTap: (id) => tapped = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.tile.01H')));
    await tester.pump();

    expect(tapped, '01H');
  });

  testWidgets('pull-to-refresh re-fetches the first page', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[
        _metaJson(id: '01H', title: 'after-$calls'),
      ]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    // Drive the controller directly. The RefreshIndicator's onRefresh is
    // bound to this same method, so we exercise the same behavior without
    // needing the gesture machinery.
    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('after-2'), findsOneWidget);
  });

  testWidgets('a refresh action in the AppBar re-fetches the first page',
      (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[_metaJson(id: '01H', title: 'after-$calls')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          appBarActions: [
            IconButton(
              key: const Key('shell.refresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: ctrl.refresh,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('shell.refresh')));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('after-2'), findsOneWidget);
  });

  testWidgets('a failed refresh shows a banner and keeps loaded items',
      (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      if (calls == 1) {
        return _page(<Object?>[_metaJson(id: '01H', title: 'still here')]);
      }
      return http.Response(
        jsonEncode(<String, Object?>{'message': 'database is locked'}),
        500,
      );
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notes.error')), findsNothing);

    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notes.error')), findsOneWidget);
    expect(find.text('database is locked'), findsOneWidget);
    expect(find.text('still here'), findsOneWidget);
  });

  testWidgets('the error banner retry re-fetches and clears the banner',
      (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      if (calls == 1) {
        return http.Response('', 503);
      }
      return _page(<Object?>[_metaJson(id: '01H', title: 'recovered')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notes.error')), findsOneWidget);
    expect(find.text('Could not load notes.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.byKey(const Key('notes.error')), findsNothing);
    expect(find.text('recovered'), findsOneWidget);
  });

  group('formatNoteTimestamp', () {
    test('renders YYYY-MM-DD HH:MM with zero padding and no UTC marker', () {
      expect(
        formatNoteTimestamp(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02 03:04',
      );
    });

    test('renders a UTC instant as the local wall-clock time', () {
      final utc = DateTime.utc(2026, 9, 12, 10, 28);
      final l = utc.toLocal();
      final wallClock = DateTime(l.year, l.month, l.day, l.hour, l.minute);

      expect(formatNoteTimestamp(utc), formatNoteTimestamp(wallClock));
    });
  });

  testWidgets('the tile subtitle uses formatNoteTimestamp', (tester) async {
    final mock = MockClient((request) async {
      return _page(<Object?>[_metaJson(id: '01H')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    final expected = formatNoteTimestamp(DateTime.parse(_now));
    expect(find.text('v1 · $expected'), findsOneWidget);
  });
}
