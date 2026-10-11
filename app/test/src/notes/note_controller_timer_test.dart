import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NoteController _controller() => NoteController(
  noteId: '01H',
  actor: 'tester',
  api: RobotNotesClient(
    config: const AppConfig(
      baseUrl: 'https://notes.example',
      apiKey: 'test-key',
      actor: 'tester',
    ),
    httpClient: MockClient((request) async {
      if (request.method == 'DELETE') return http.Response('', 204);
      if (request.url.path.endsWith('/lock')) {
        return http.Response(
          jsonEncode({
            'holder': 'tester',
            'expires_at': '2099-01-01T00:00:00.000Z',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/backlinks')) {
        return http.Response('{"items":[]}', 200);
      }
      return http.Response(
        jsonEncode({
          'id': '01H',
          'version': 1,
          'title': 'Title',
          'content': 'Original',
          'created_at': '2025-01-01T00:00:00.000Z',
          'updated_at': '2025-01-01T00:00:00.000Z',
        }),
        200,
      );
    }),
  ),
);

void main() {
  testWidgets(
    'disposing an editor cancels owned heartbeat and autosave timers',
    (tester) async {
      final controller = _controller();
      await controller.open();
      await controller.enterEditMode();
      controller.setEditContent('Draft');
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('exiting editing cancels owned heartbeat and autosave timers', (
    tester,
  ) async {
    final controller = _controller();
    await controller.open();
    await controller.enterEditMode();
    controller.setEditContent('Draft');
    await controller.exitEditing();
    expect(controller.value.mode, NoteMode.viewing);
    controller.dispose();
    await tester.pump();
  });
}
