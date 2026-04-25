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

void main() {
  testWidgets('initial render fetches the first page', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[
            _metaJson(id: '01H', title: 'hello'),
            _metaJson(id: '02H', title: 'world'),
          ],
          'limit': 50,
          'next_cursor': null,
        }),
        200,
      );
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
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[_metaJson(id: '01H', title: 'tap me')],
          'limit': 50,
          'next_cursor': null,
        }),
        200,
      );
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
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[
            _metaJson(id: '01H', title: 'after-$calls'),
          ],
          'limit': 50,
          'next_cursor': null,
        }),
        200,
      );
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
}
