import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/desktop/app_menu_actions.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/notes/block_note_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How the note view publishes its commands to the macOS menu bar's Note
/// menu (via [AppMenuActions]) as its state changes.
const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _noteJson({int version = 1}) => <String, Object?>{
  'id': '01H',
  'title': 'hello',
  'content': 'world',
  'version': version,
  'path': '',
  'created_at': _now,
  'updated_at': _now,
  'tags': <String>[],
};

Map<String, Object?> _lockJson() => <String, Object?>{
  'holder': 'cedric',
  'expires_at': '2099-01-01T00:00:00.000Z',
};

RobotNotesClient _api(List<String> calls) => RobotNotesClient(
  config: _config,
  httpClient: MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    if (request.method == 'GET' && request.url.path == '/notes/01H') {
      return http.Response(jsonEncode(_noteJson()), 200);
    }
    if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
      return http.Response(jsonEncode(_lockJson()), 200);
    }
    if (request.method == 'DELETE' && request.url.path == '/notes/01H/lock') {
      return http.Response('', 204);
    }
    if (request.method == 'PUT' && request.url.path == '/notes/01H') {
      return http.Response(jsonEncode(_noteJson(version: 2)), 200);
    }
    return http.Response('unexpected', 500);
  }),
);

NoteController _controller(RobotNotesClient api) => NoteController(
  api: api,
  noteId: '01H',
  actor: 'cedric',
  scheduler: (_) => Completer<void>().future,
  autosaveScheduler: (_) => Completer<void>().future,
);

void main() {
  testWidgets('registers nothing when hosted without a registry', (
    tester,
  ) async {
    final ctrl = _controller(_api(<String>[]));
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
    await tester.pumpAndSettle();

    expect(find.byType(BlockNoteEditor), findsOneWidget);
  });

  testWidgets(
    'publishes Save/Move/Delete/Close during editing and withdraws on dispose',
    (tester) async {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final calls = <String>[];
      final ctrl = _controller(_api(calls));
      addTearDown(ctrl.dispose);
      var closed = false;

      await tester.pumpWidget(
        AppMenuActionsScope(
          actions: actions,
          child: MaterialApp(
            home: NoteScreen(controller: ctrl, onClose: () => closed = true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(actions.note.edit, isNull);
      expect(actions.note.move, isNotNull);
      expect(actions.note.delete, isNotNull);
      expect(actions.note.close, isNotNull);
      expect(actions.note.save, isNotNull);
      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(
        calls.where((call) => call == 'POST /notes/01H/lock'),
        hasLength(1),
      );

      // Save from the menu sends the PUT.
      actions.note.save!();
      await tester.pumpAndSettle();
      expect(calls, contains('PUT /notes/01H'));
      expect(find.text('Saved (v2)'), findsOneWidget);

      // Close Note from the menu.
      actions.note.close!();
      await tester.pumpAndSettle();
      expect(closed, isTrue);

      await tester.pumpWidget(
        AppMenuActionsScope(
          actions: actions,
          child: const MaterialApp(home: SizedBox.shrink()),
        ),
      );
      expect(actions.note.close, isNull);
      expect(actions.note.edit, isNull);
    },
  );

  testWidgets('a note pushed on top takes the Note menu and hands it back', (
    tester,
  ) async {
    final actions = AppMenuActions();
    addTearDown(actions.dispose);
    final api = _api(<String>[]);
    final below = _controller(api);
    final above = _controller(api);
    addTearDown(below.dispose);
    addTearDown(above.dispose);
    var belowSaves = 0;
    late NavigatorState navigator;

    await tester.pumpWidget(
      AppMenuActionsScope(
        actions: actions,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              navigator = Navigator.of(context);
              return NoteScreen(controller: below);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final belowSave = actions.note.save;
    expect(belowSave, isNotNull);

    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => NoteScreen(controller: above)),
      ),
    );
    await tester.pumpAndSettle();
    // The top note now owns the menu; it is a different handler.
    expect(actions.note.save, isNotNull);
    expect(identical(actions.note.save, belowSave), isFalse);

    navigator.pop();
    await tester.pumpAndSettle();
    // The note underneath has re-registered, and its handler works.
    expect(actions.note.save, isNotNull);
    below.addListener(() {
      if (below.value.mode == NoteMode.saving) belowSaves++;
    });
    actions.note.save!();
    await tester.pumpAndSettle();
    expect(belowSaves, greaterThan(0));
    expect(find.byType(BlockNoteEditor), findsOneWidget);
  });
}
