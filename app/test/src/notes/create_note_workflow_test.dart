import 'dart:convert';

import 'package:app/main.dart';
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

http.Response _emptyList() => http.Response(
      jsonEncode(<String, Object?>{
        'items': <Object?>[],
        'limit': 50,
        'next_cursor': null,
      }),
      200,
    );

void main() {
  group('createBlankNote', () {
    test('uses YYYY-MM-DD <Untitled> derived from the supplied clock', () {
      // The bug we are guarding against: the FAB used to send
      // `title: ''` and the server rejected it with 400. The client
      // must now send a non-empty title; date-prefixing keeps the
      // listing roughly chronological even before the user renames.
      expect(blankNoteTitle(DateTime(2026, 4, 25)), '2026-04-25 Untitled');
      expect(blankNoteTitle(DateTime(2024, 1, 9)), '2024-01-09 Untitled');
    });

    test('POSTs /notes with the date-prefixed title and empty content',
        () async {
      String? capturedBody;
      String? capturedMethod;
      String? capturedPath;
      final mock = MockClient((request) async {
        capturedMethod = request.method;
        capturedPath = request.url.path;
        capturedBody = request.body;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': '01H',
            'title': body['title'],
            'content': body['content'],
            'version': 1,
            'created_at': _now,
            'updated_at': _now,
          }),
          201,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);

      final note = await createBlankNote(api, now: DateTime(2026, 4, 25));

      expect(capturedMethod, 'POST');
      expect(capturedPath, '/notes');
      final sent = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(sent['title'], '2026-04-25 Untitled');
      expect(sent['content'], '');
      expect(note.id, '01H');
      expect(note.title, '2026-04-25 Untitled');
    });
  });

  testWidgets(
      'tapping the create FAB issues a POST /notes that the '
      'server would accept', (tester) async {
    // End-to-end of the FAB workflow: render NotesListScreen, tap the
    // FAB, observe the resulting HTTP request. The test fails if the
    // outbound `title` is empty, which is exactly the regression this
    // change fixes — the original implementation sent `title: ''` and
    // got rejected with 400 by the server's title validation.
    String? createBody;
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/notes') {
        createBody = request.body;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': '01H',
            'title': body['title'],
            'content': body['content'],
            'version': 1,
            'created_at': _now,
            'updated_at': _now,
          }),
          201,
        );
      }
      return _emptyList();
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          onCreate: () => createBlankNote(api, now: DateTime(2026, 4, 25)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();

    expect(createBody, isNotNull, reason: 'POST /notes should fire');
    final sent = jsonDecode(createBody!) as Map<String, dynamic>;
    expect(
      sent['title'],
      isA<String>().having((t) => t.trim(), 'trim()', isNotEmpty),
      reason: 'server rejects empty titles with 400 — client must always send '
          'a non-empty title',
    );
    expect(sent['title'], '2026-04-25 Untitled');
  });
}
