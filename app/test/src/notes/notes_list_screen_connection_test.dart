import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:app/src/widgets/connection_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

http.Response _page(String title) => http.Response(
  jsonEncode(<String, Object?>{
    'items': <Object?>[
      <String, Object?>{
        'id': '01H',
        'title': title,
        'version': 1,
        'created_at': '2025-01-01T00:00:00.000Z',
        'updated_at': '2025-01-01T00:00:00.000Z',
      },
    ],
    'limit': 50,
    'next_cursor': null,
  }),
  200,
);

void main() {
  testWidgets('the banner slot renders above the list', (tester) async {
    final mock = MockClient((request) async => _page('hello'));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          banner: const Text('banner', key: Key('test.banner')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final banner = tester.getRect(find.byKey(const Key('test.banner')));
    final list = tester.getRect(find.byKey(const Key('notes.list')));
    expect(banner.bottom, lessThanOrEqualTo(list.top));
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('reconnecting after a stale outage re-fetches the list', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page('after-$calls');
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final events = StreamController<RealtimeEvent>.broadcast();
    final ctrl = NotesListController(api: api, events: events.stream);
    final status = ConnectionStatusController(
      events: events.stream,
      onStaleReconnect: ctrl.refresh,
    );
    addTearDown(() async {
      status.dispose();
      ctrl.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          banner: ConnectionBanner(status: status),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection.banner')), findsOneWidget);

    events.add(const WsConnected());
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('connection.banner')), findsNothing);

    events.add(const WsDisconnected());
    events.add(const WsStale());
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('connection.banner')), findsOneWidget);
    expect(find.text('after-1'), findsOneWidget);

    events.add(const WsConnected());
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const Key('connection.banner')), findsNothing);
    expect(find.text('after-2'), findsOneWidget);
  });
}
