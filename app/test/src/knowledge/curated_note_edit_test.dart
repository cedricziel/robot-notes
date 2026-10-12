import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('proposal-only identity never acquires accepted editor lock', (
    tester,
  ) async {
    var locks = 0;
    final api = RobotNotesClient(
      config: const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'agent',
        actor: 'Human label',
      ),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/lock')) locks++;
        if (request.url.path.endsWith('/permissions')) {
          return http.Response(
            '{"curated":true,"principal_kind":"agent","allowed_actions":["read","propose"]}',
            200,
          );
        }
        if (request.url.path == '/notes/n') {
          return http.Response(
            jsonEncode({
              'id': 'n',
              'title': 'Curated',
              'content': 'Accepted knowledge',
              'version': 1,
              'created_at': '2026-10-11T00:00:00Z',
              'updated_at': '2026-10-11T00:00:00Z',
            }),
            200,
          );
        }
        return http.Response('{"items":[]}', 200);
      }),
    );
    final controller = NoteController(
      api: api,
      noteId: 'n',
      actor: 'Human label',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: NoteScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(locks, 0);
    expect(controller.value.mode, NoteMode.viewing);
    expect(find.text('Knowledge review'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Propose update'), findsOneWidget);
    await tester.tap(find.byKey(const Key('note.edit')));
    await tester.pumpAndSettle();
    expect(locks, 0);
    expect(controller.value.mode, NoteMode.viewing);
    expect(find.text('Knowledge review'), findsOneWidget);
  });
}
