import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
}) => <String, Object?>{
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
}) => <String, Object?>{'holder': holder, 'expires_at': expiresAt};

const _titleField = Key('note.editor.title');
const _contentField = Key('note.editor.content');
const _conflictTitleField = Key('note.conflict.title');
const _conflictContentField = Key('note.conflict.content');

TextEditingController _fieldController(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!;

/// Text of every span in [span] that carries a diff highlight.
List<String> _markedLines(InlineSpan span) {
  final marked = <String>[];
  span.visitChildren((child) {
    if (child is TextSpan && child.style?.backgroundColor != null) {
      marked.add(child.text!);
    }
    return true;
  });
  return marked;
}

/// Pumps a [NoteScreen] into edit mode, by tapping edit or, with
/// [startEditing], by opening straight into it. [onLock] answers the
/// `POST /notes/{id}/lock` (granted by default); [onSave] answers the
/// `PUT /notes/{id}` the save button sends.
Future<NoteController> _pumpEditor(
  WidgetTester tester, {
  http.Response Function(http.Request)? onLock,
  http.Response Function(http.Request)? onSave,
  bool startEditing = false,
}) async {
  final mock = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/notes/01H') {
      return http.Response(jsonEncode(_noteJson()), 200);
    }
    if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
      return onLock?.call(request) ??
          http.Response(jsonEncode(_lockJson()), 200);
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

  await tester.pumpWidget(
    MaterialApp(
      home: NoteScreen(controller: ctrl, startEditing: startEditing),
    ),
  );
  await tester.pumpAndSettle();
  if (startEditing) return ctrl;
  await tester.tap(find.byKey(const Key('note.edit')));
  await tester.pumpAndSettle();
  return ctrl;
}

MockClient _editableNote({VoidCallback? onRelease}) =>
    MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/notes/01H') {
        return http.Response(jsonEncode(_noteJson()), 200);
      }
      if (request.method == 'POST' && path == '/notes/01H/lock') {
        return http.Response(jsonEncode(_lockJson()), 200);
      }
      if (request.method == 'DELETE' && path == '/notes/01H/lock') {
        onRelease?.call();
        return http.Response('', 204);
      }
      return http.Response('unexpected', 500);
    });

/// Pumps a [NoteScreen] into conflict mode: types the local edits, then
/// saves against a server that answers the first `PUT` with a 409 at
/// version 3. Later `PUT`s go to [onRetry]; every `PUT` is recorded in
/// [puts].
Future<void> _pumpConflict(
  WidgetTester tester, {
  String serverTitle = 'hello',
  required String serverContent,
  String? myTitle,
  required String myContent,
  http.Response Function(http.Request)? onRetry,
  List<http.Request>? puts,
}) async {
  final conflict = http.Response(
    jsonEncode(<String, Object?>{
      'error': 'version_conflict',
      'current': _noteJson(
        title: serverTitle,
        content: serverContent,
        version: 3,
      ),
    }),
    409,
  );
  var saves = 0;
  await _pumpEditor(
    tester,
    onSave: (request) {
      saves += 1;
      puts?.add(request);
      if (saves == 1) return conflict;
      return onRetry?.call(request) ?? http.Response('unexpected', 500);
    },
  );

  if (myTitle != null) {
    await tester.enterText(find.byKey(_titleField), myTitle);
  }
  await tester.enterText(find.byKey(_contentField), myContent);
  await tester.tap(find.byKey(const Key('note.save')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('note.banner.conflict')), findsOneWidget);
}

/// Pumps a [NoteScreen] showing a note with [content] in read-only mode.
Future<void> _pumpViewer(WidgetTester tester, {required String content}) async {
  final mock = MockClient((request) async {
    return http.Response(jsonEncode(_noteJson(content: content)), 200);
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
  addTearDown(ctrl.dispose);

  await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the note body in read-only view by default', (
    tester,
  ) async {
    await _pumpViewer(tester, content: 'body text');

    expect(find.byKey(const Key('note.body')), findsOneWidget);
    expect(find.text('body text'), findsOneWidget);
    expect(find.byKey(const Key('note.edit')), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byTooltip('Edit'), findsOneWidget);
  });

  testWidgets('read-only view renders the body as Markdown', (tester) async {
    await _pumpViewer(tester, content: '# Heading\n\n- item\n\n`code`');

    final body = find.byKey(const Key('note.body'));
    Finder inBody(String text) =>
        find.descendant(of: body, matching: find.text(text));

    final heading = inBody('Heading');
    final item = inBody('item');
    expect(heading, findsOneWidget);
    expect(item, findsOneWidget);
    expect(inBody('code'), findsOneWidget);
    expect(
      tester.getSize(heading).height,
      greaterThan(tester.getSize(item).height),
    );
  });

  testWidgets('read-only view shows image alt text instead of loading images', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      content: '![tracker pixel](https://example.com/pixel.png)',
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text('tracker pixel'), findsOneWidget);
  });

  testWidgets('tapping edit acquires the lock and reveals the editor', (
    tester,
  ) async {
    await _pumpEditor(tester);

    expect(find.byKey(_titleField), findsOneWidget);
    expect(find.byKey(_contentField), findsOneWidget);
    expect(find.byKey(const Key('note.save')), findsOneWidget);
  });

  testWidgets('typing in the middle of a field keeps the caret there', (
    tester,
  ) async {
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

  testWidgets('editor fields follow the buffers after accepting the server', (
    tester,
  ) async {
    await _pumpConflict(tester, serverContent: 'theirs', myContent: 'mine');

    await tester.tap(find.byKey(const Key('note.conflict.acceptServer')));
    await tester.pumpAndSettle();

    expect(_fieldController(tester, _contentField).text, 'theirs');
  });

  testWidgets('startEditing opens the editor with the title selected', (
    tester,
  ) async {
    await _pumpEditor(tester, startEditing: true);

    expect(find.byKey(_titleField), findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(_titleField),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(
      _fieldController(tester, _titleField).selection,
      const TextSelection(baseOffset: 0, extentOffset: 'hello'.length),
    );
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

  group('closing while editing', () {
    var lockReleases = 0;
    var closed = false;

    setUp(() {
      lockReleases = 0;
      closed = false;
    });

    NoteController controller() {
      final ctrl = NoteController(
        api: RobotNotesClient(
          config: _config,
          httpClient: _editableNote(onRelease: () => lockReleases++),
        ),
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
      );
      addTearDown(ctrl.dispose);
      return ctrl;
    }

    Future<void> enterEditMode(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.edit')));
      await tester.pumpAndSettle();
    }

    Future<NoteController> pumpEditing(WidgetTester tester) async {
      final ctrl = controller();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteScreen(controller: ctrl, onClose: () => closed = true),
        ),
      );
      await enterEditMode(tester);
      return ctrl;
    }

    Future<void> editContent(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('note.editor.content')),
        'world, edited',
      );
      await tester.pump();
    }

    Future<void> tapClose(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();
    }

    testWidgets('without edits releases the lock and closes with no prompt', (
      tester,
    ) async {
      final ctrl = await pumpEditing(tester);

      await tapClose(tester);

      expect(find.text('Discard changes?'), findsNothing);
      expect(ctrl.value.mode, NoteMode.viewing);
      expect(lockReleases, 1);
      expect(closed, isTrue);
    });

    testWidgets('with unsaved edits, keep editing dismisses the prompt', (
      tester,
    ) async {
      final ctrl = await pumpEditing(tester);
      await editContent(tester);

      await tapClose(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(closed, isFalse);

      await tester.tap(find.byKey(const Key('note.discard.keep')));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(closed, isFalse);
      expect(ctrl.value.mode, NoteMode.editing);
      expect(ctrl.value.editContent, 'world, edited');
      expect(lockReleases, 0);
    });

    testWidgets('with unsaved edits, discard exits editing and closes', (
      tester,
    ) async {
      final ctrl = await pumpEditing(tester);
      await editContent(tester);
      await tapClose(tester);

      await tester.tap(find.byKey(const Key('note.discard.confirm')));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(ctrl.value.mode, NoteMode.viewing);
      expect(lockReleases, 1);
      expect(closed, isTrue);
    });

    testWidgets('system back with unsaved edits prompts before popping', (
      tester,
    ) async {
      final ctrl = controller();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => NoteScreen(
                      controller: ctrl,
                      onClose: () => Navigator.of(context).pop(),
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
      await enterEditMode(tester);
      await editContent(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.byKey(const Key('note.editor.content')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note.discard.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note.editor.content')), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);
      expect(lockReleases, 1);
    });
  });

  group('keyboard shortcuts', () {
    testWidgets('Cmd+S saves while a text field has focus', (tester) async {
      await _pumpEditor(
        tester,
        onSave: (_) => http.Response(jsonEncode(_noteJson(version: 2)), 200),
      );
      await tester.tap(find.byKey(_contentField));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(find.text('Saved (v2)'), findsOneWidget);
    });

    testWidgets('Ctrl+S saves while a text field has focus', (tester) async {
      await _pumpEditor(
        tester,
        onSave: (_) => http.Response(jsonEncode(_noteJson(version: 3)), 200),
      );
      await tester.tap(find.byKey(_titleField));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('Saved (v3)'), findsOneWidget);
    });

    testWidgets('Escape while dirty shows the discard prompt', (tester) async {
      await _pumpEditor(tester);
      await tester.tap(find.byKey(_contentField));
      await tester.enterText(find.byKey(_contentField), 'edited');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
    });

    testWidgets('Cmd+S while only viewing sends no request and no snackbar', (
      tester,
    ) async {
      var putCalls = 0;
      final mock = MockClient((request) async {
        if (request.method == 'PUT') putCalls += 1;
        return http.Response(jsonEncode(_noteJson()), 200);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
      await tester.pumpAndSettle();
      // Give the body focus first — like tapping into the read-only note —
      // so the key event has somewhere to start bubbling from.
      await tester.tap(find.byKey(const Key('note.body')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(putCalls, 0);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('feedback', () {
    testWidgets('a failed save shows the server message', (tester) async {
      final ctrl = await _pumpEditor(
        tester,
        onSave: (_) => http.Response(
          jsonEncode({'message': 'title must not be empty'}),
          400,
        ),
      );

      await tester.tap(find.byKey(const Key('note.save')));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('Could not save: title must not be empty'),
        findsOneWidget,
      );
      expect(ctrl.value.mode, NoteMode.editing);
    });

    testWidgets('a successful save confirms the new version', (tester) async {
      await _pumpEditor(
        tester,
        onSave: (_) => http.Response(jsonEncode(_noteJson(version: 2)), 200),
      );

      await tester.tap(find.byKey(const Key('note.save')));
      await tester.pumpAndSettle();

      expect(find.text('Saved (v2)'), findsOneWidget);
    });

    testWidgets('failing to acquire the lock shows the server message', (
      tester,
    ) async {
      final ctrl = await _pumpEditor(
        tester,
        onLock: (_) => http.Response(jsonEncode({'message': 'boom'}), 500),
      );

      expect(find.text('Could not start editing: boom'), findsOneWidget);
      expect(ctrl.value.mode, NoteMode.viewing);
    });

    testWidgets('a 423 on edit shows the lock banner without a snackbar', (
      tester,
    ) async {
      await _pumpEditor(
        tester,
        onLock: (_) => http.Response(
          jsonEncode({'message': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        ),
      );

      expect(find.byKey(const Key('note.banner.lock')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a failed load replaces the spinner with the server message', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode({'message': 'down'}), 500);
      });
      final ctrl = NoteController(
        api: RobotNotesClient(config: _config, httpClient: mock),
        noteId: '01H',
        actor: 'cedric',
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note.loadError')), findsOneWidget);
      expect(find.text('Could not load the note: down'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  testWidgets('conflict view shows the server title next to yours', (
    tester,
  ) async {
    await _pumpConflict(
      tester,
      serverTitle: 'server title',
      serverContent: 'theirs',
      myTitle: 'my title',
      myContent: 'mine',
    );

    expect(find.text('server title'), findsOneWidget);
    expect(_fieldController(tester, _conflictTitleField).text, 'my title');
    expect(_fieldController(tester, _conflictContentField).text, 'mine');
    expect(find.text('Save mine'), findsOneWidget);
  });

  testWidgets('editing yours in the conflict view then saving mine sends it', (
    tester,
  ) async {
    final puts = <http.Request>[];
    await _pumpConflict(
      tester,
      serverContent: 'theirs',
      myContent: 'mine',
      puts: puts,
      onRetry: (_) => http.Response(
        jsonEncode(_noteJson(content: 'merged', version: 4)),
        200,
      ),
    );

    await tester.enterText(find.byKey(_conflictContentField), 'merged');
    await tester.tap(find.byKey(const Key('note.conflict.keepMine')));
    await tester.pumpAndSettle();

    expect(puts, hasLength(2));
    expect(puts.last.headers['If-Match'], '3');
    expect(jsonDecode(puts.last.body), containsPair('content', 'merged'));
    expect(_fieldController(tester, _contentField).text, 'merged');
  });

  testWidgets('conflict view marks the lines the two versions do not share', (
    tester,
  ) async {
    await _pumpConflict(tester, serverContent: 'a\nb\nc', myContent: 'a\nb\nd');

    final server = tester
        .widget<SelectableText>(
          find.byKey(const Key('note.conflict.serverContent')),
        )
        .textSpan!;
    expect(_markedLines(server), ['c']);

    final yours = find.byKey(_conflictContentField);
    final mine = _fieldController(
      tester,
      _conflictContentField,
    ).buildTextSpan(context: tester.element(yours), withComposing: false);
    expect(_markedLines(mine), ['d']);
  });

  testWidgets('conflict panes stack vertically on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpConflict(tester, serverContent: 'theirs', myContent: 'mine');

    final server = tester.getRect(
      find.byKey(const Key('note.conflict.server')),
    );
    final yours = tester.getRect(find.byKey(const Key('note.conflict.yours')));
    expect(yours.top, greaterThanOrEqualTo(server.bottom));
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

    await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
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

  testWidgets('lock event from another holder shows an info banner', (
    tester,
  ) async {
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

    await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
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

  group('delete', () {
    /// Pumps a read-only note, opens the overflow menu, and picks
    /// "Delete note" so the confirm dialog is showing. Records requests in
    /// the returned list; `DELETE /notes/01H` answers with [deleteStatus].
    Future<List<String>> pumpAndOpenDeleteDialog(
      WidgetTester tester, {
      required VoidCallback onClose,
      int deleteStatus = 204,
    }) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
          return http.Response('', deleteStatus);
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteScreen(controller: ctrl, onClose: onClose),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.delete')));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets(
      'confirming deletes the note, closes it, and shows a snackbar',
      (tester) async {
        var closed = 0;
        final calls = await pumpAndOpenDeleteDialog(
          tester,
          onClose: () => closed += 1,
        );
        expect(find.text('Delete this note?'), findsOneWidget);

        await tester.tap(find.byKey(const Key('note.delete.confirm')));
        await tester.pumpAndSettle();

        expect(calls, contains('DELETE /notes/01H'));
        expect(closed, 1);
        expect(find.text('Note deleted'), findsOneWidget);
      },
    );

    testWidgets('a failed delete keeps the note open and says so', (
      tester,
    ) async {
      var closed = 0;
      await pumpAndOpenDeleteDialog(
        tester,
        onClose: () => closed += 1,
        deleteStatus: 500,
      );

      await tester.tap(find.byKey(const Key('note.delete.confirm')));
      await tester.pumpAndSettle();

      expect(closed, 0);
      expect(find.byKey(const Key('note.body')), findsOneWidget);
      expect(find.text("Couldn't delete the note"), findsOneWidget);
    });

    testWidgets('cancelling keeps the note and sends no request', (
      tester,
    ) async {
      var closed = 0;
      final calls = await pumpAndOpenDeleteDialog(
        tester,
        onClose: () => closed += 1,
      );

      await tester.tap(find.byKey(const Key('note.delete.cancel')));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(closed, 0);
      expect(find.byKey(const Key('note.body')), findsOneWidget);
    });
  });
}
