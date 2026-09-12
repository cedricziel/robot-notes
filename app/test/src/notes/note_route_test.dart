import 'dart:convert';

import 'package:app/main.dart';
import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/realtime/ws_client.dart';
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

Map<String, Object?> _noteJson() => <String, Object?>{
      'id': '01H',
      'title': 'hello',
      'content': 'world',
      'version': 1,
      'created_at': _now,
      'updated_at': _now,
    };

void main() {
  testWidgets('the close button pops the note route', (tester) async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode(_noteJson()), 200);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    addTearDown(api.close);
    final ws = RobotNotesWsClient(config: _config);
    addTearDown(ws.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => NoteRoute(
                    api: api,
                    ws: ws,
                    actor: 'cedric',
                    noteId: '01H',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note.body')), findsOneWidget);

    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.body')), findsNothing);
    expect(find.byKey(const Key('open')), findsOneWidget);
  });
}
