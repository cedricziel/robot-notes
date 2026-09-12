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

const _titleField = Key('note.editor.title');
const _contentField = Key('note.editor.content');

TextEditingController _fieldController(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!;

/// Pumps a [NoteScreen] whose note is already in edit mode. [onSave]
/// answers the `PUT /notes/{id}` the save button sends.
Future<void> _pumpEditor(
  WidgetTester tester, {
  http.Response Function(http.Request)? onSave,
}) async {
  final mock = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/notes/01H') {
      return http.Response(jsonEncode(_noteJson()), 200);
    }
    if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
      return http.Response(jsonEncode(_lockJson()), 200);
    }
    if (request.method == 'PUT' && request.url.path == '/notes/01H') {
      return onSave?.call(request) ?? http.Response('unexpected', 500);
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

  await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('note.edit')));
  await tester.pumpAndSettle();
}

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
    await _pumpEditor(tester);

    expect(find.byKey(_titleField), findsOneWidget);
    expect(find.byKey(_contentField), findsOneWidget);
    expect(find.byKey(const Key('note.save')), findsOneWidget);
  });

  testWidgets('typing in the middle of a field keeps the caret there',
      (tester) async {
    await _pumpEditor(tester);

    await tester.showKeyboard(find.byKey(_titleField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'hXello',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    final title = _fieldController(tester, _titleField);
    expect(title.text, 'hXello');
    expect(title.selection.baseOffset, 2);
  });

  testWidgets('editor fields follow the buffers after a save', (tester) async {
    await _pumpEditor(
      tester,
      onSave: (_) => http.Response(
        jsonEncode(
          _noteJson(title: 'server title', content: 'server body', version: 2),
        ),
        200,
      ),
    );

    await tester.enterText(find.byKey(_contentField), 'draft');
    await tester.tap(find.byKey(const Key('note.save')));
    await tester.pumpAndSettle();

    expect(_fieldController(tester, _titleField).text, 'server title');
    expect(_fieldController(tester, _contentField).text, 'server body');
  });

  testWidgets('editor fields follow the buffers after accepting the server',
      (tester) async {
    await _pumpEditor(
      tester,
      onSave: (_) => http.Response(
        jsonEncode(<String, Object?>{
          'error': 'version_conflict',
          'current': _noteJson(content: 'theirs', version: 3),
        }),
        409,
      ),
    );

    await tester.enterText(find.byKey(_contentField), 'mine');
    await tester.tap(find.byKey(const Key('note.save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note.banner.conflict')), findsOneWidget);

    await tester.tap(find.byKey(const Key('note.conflict.acceptServer')));
    await tester.pumpAndSettle();

    expect(_fieldController(tester, _contentField).text, 'theirs');
  });

  testWidgets('tapping close in viewing mode calls onClose', (tester) async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode(_noteJson()), 200);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
    addTearDown(ctrl.dispose);
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: NoteScreen(controller: ctrl, onClose: () => closed = true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });

  testWidgets('tapping close while editing releases the lock, then closes',
      (tester) async {
    final mock = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/notes/01H') {
        return http.Response(jsonEncode(_noteJson()), 200);
      }
      if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
        return http.Response(jsonEncode(_lockJson()), 200);
      }
      if (request.method == 'DELETE' && request.url.path == '/notes/01H/lock') {
        return http.Response('', 204);
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
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: NoteScreen(controller: ctrl, onClose: () => closed = true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.edit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();

    expect(ctrl.value.mode, NoteMode.viewing);
    expect(closed, isTrue);
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
