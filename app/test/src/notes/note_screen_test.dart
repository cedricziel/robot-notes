import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _noteJson({
  String id = '01H',
  String title = 'hello',
  String content = 'world',
  int version = 1,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'content': content,
      'version': version,
      'created_at': _now,
      'updated_at': _now,
    };

Map<String, Object?> _lockJson({
  String holder = 'cedric',
  String expiresAt = '2025-01-01T00:01:00.000Z',
}) =>
    <String, Object?>{'holder': holder, 'expires_at': expiresAt};

void main() {
  testWidgets('renders the note body in read-only view by default',
      (tester) async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode(_noteJson(content: 'body text')), 200);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NoteController(
      api: api,
      noteId: '01H',
      actor: 'cedric',
    );
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NoteScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.body')), findsOneWidget);
    expect(find.text('body text'), findsOneWidget);
    expect(find.byKey(const Key('note.edit')), findsOneWidget);
  });

  testWidgets('tapping edit acquires the lock and reveals the editor',
      (tester) async {
    final mock = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/notes/01H') {
        return http.Response(jsonEncode(_noteJson()), 200);
      }
      if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
        return http.Response(jsonEncode(_lockJson()), 200);
      }
      return http.Response('unexpected', 500);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NoteController(
      api: api,
      noteId: '01H',
      actor: 'cedric',
      scheduler: (_) => Completer<void>().future,
    );
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NoteScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('note.edit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.editor.title')), findsOneWidget);
    expect(find.byKey(const Key('note.editor.content')), findsOneWidget);
    expect(find.byKey(const Key('note.save')), findsOneWidget);
  });

  testWidgets('presence event renders the viewer count', (tester) async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode(_noteJson()), 200);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final events = StreamController<RealtimeEvent>.broadcast();
    addTearDown(events.close);
    final ctrl = NoteController(
      api: api,
      noteId: '01H',
      actor: 'cedric',
      events: events.stream,
    );
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NoteScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    events.add(
      const RealtimeMessage(
        PresenceEvent(noteId: '01H', viewers: <String>['cedric', 'alice']),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.presence')), findsOneWidget);
    expect(find.textContaining('viewers'), findsOneWidget);
  });

  testWidgets('lock event from another holder shows an info banner',
      (tester) async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode(_noteJson()), 200);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final events = StreamController<RealtimeEvent>.broadcast();
    addTearDown(events.close);
    final ctrl = NoteController(
      api: api,
      noteId: '01H',
      actor: 'cedric',
      events: events.stream,
    );
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NoteScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    events.add(
      RealtimeMessage(
        LockEvent(
          noteId: '01H',
          holder: 'alice',
          expiresAt: DateTime.utc(2025, 1, 1, 0, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.banner.lock')), findsOneWidget);
    expect(find.textContaining('alice'), findsOneWidget);
  });
}
