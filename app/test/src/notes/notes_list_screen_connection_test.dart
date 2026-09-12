import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
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
  // The banner itself now lives in `SessionHost` (see app_router_test.dart
  // for router-level coverage); this exercises the stale→connected refetch
  // that used to be asserted through NotesListScreen's removed `banner` slot.
  test('ConnectionStatusController.onStaleReconnect re-fetches the list after '
      'a stale outage reconnects', () async {
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

    await ctrl.refresh();
    expect(calls, 1);

    events.add(const WsConnected());
    await pumpEventQueue();
    expect(status.value, ConnectionStatus.connected);
    expect(calls, 1, reason: 'a plain (non-stale) reconnect refetches nothing');

    events.add(const WsDisconnected());
    events.add(const WsStale());
    await pumpEventQueue();
    expect(status.value, ConnectionStatus.stale);
    expect(calls, 1);

    events.add(const WsConnected());
    await pumpEventQueue();
    expect(status.value, ConnectionStatus.connected);
    expect(
      calls,
      2,
      reason: 'stale→connected should trigger exactly one refetch',
    );
    expect(ctrl.value.items.single.title, 'after-2');
  });
}
