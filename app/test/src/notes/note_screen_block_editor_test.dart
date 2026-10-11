import 'dart:async';
import 'dart:convert';

import 'package:adaptive_super_editor/adaptive_super_editor.dart';
import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'existing note acquires lock and opens blocks without keyboard focus',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      expect(fixture.acquisitions, 1);
      expect(fixture.reads, 2);
      expect(fixture.controller.value.mode, NoteMode.editing);
      expect(find.byType(AdaptiveSuperEditor), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(fixture.controller.value.isDirty, isFalse);
    },
  );

  testWidgets('source option preserves original Markdown without saving', (
    tester,
  ) async {
    final fixture = _Fixture(
      content: '# Heading\r\n\r\n| A |\r\n|---|\r\n| 1 |\r\n',
    );
    await fixture.mount(tester);
    await tester.tap(find.text('Markdown source'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('note.editor.content')),
    );
    expect(field.controller!.text, fixture.content);
    expect(fixture.puts, isEmpty);
    expect(fixture.controller.value.isDirty, isFalse);
  });

  testWidgets('source typing during save survives the acknowledgement', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final fixture = _Fixture(onSave: (_) => pending.future);
    await fixture.mount(tester);
    await tester.tap(find.text('Markdown source'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('note.editor.content')),
      'Submitted',
    );
    final save = fixture.controller.save();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('note.editor.content')),
      'Latest typing',
    );
    pending.complete(_response(_note(content: 'Submitted', version: 2)));
    await save;
    await tester.pump();
    expect(fixture.controller.value.editContent, 'Latest typing');
    expect(fixture.controller.value.note!.version, 2);
    expect(fixture.controller.value.isDirty, isTrue);
  });

  testWidgets(
    'lock contention remains readable and explicit retry enters editing',
    (tester) async {
      final fixture = _Fixture(blockFirstAcquire: true);
      await fixture.mount(tester);
      expect(fixture.controller.value.mode, NoteMode.viewing);
      expect(find.textContaining('bob is editing'), findsOneWidget);
      await tester.tap(find.byKey(const Key('note.edit')));
      await tester.pumpAndSettle();
      expect(fixture.acquisitions, 2);
      expect(find.byType(AdaptiveSuperEditor), findsOneWidget);
    },
  );

  testWidgets(
    'lock loss retains the visible draft and close asks before discard',
    (tester) async {
      var closed = false;
      final fixture = _Fixture(
        onSave: (_) async =>
            _response({'error': 'locked', 'lock': _lock('bob')}, status: 423),
      );
      await fixture.mount(tester, onClose: () => closed = true);
      await tester.tap(find.text('Markdown source'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('note.editor.content')),
        'Unsaved draft',
      );
      await tester.tap(find.byKey(const Key('note.save')));
      await tester.pumpAndSettle();
      expect(fixture.controller.value.mode, NoteMode.viewing);
      expect(fixture.controller.value.editContent, 'Unsaved draft');
      final source = tester.widget<TextField>(
        find.byKey(const Key('note.editor.content')),
      );
      expect(source.controller!.text, 'Unsaved draft');
      expect(source.readOnly, isTrue);
      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.text('Keep open'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
    },
  );
  testWidgets(
    'editing retains metadata and More details with tags and backlinks',
    (tester) async {
      final fixture = _Fixture(
        path: 'Projects',
        tags: ['work'],
        backlinks: [
          {
            'id': '02H',
            'title': 'Linked note',
            'snippet': 'References this note',
          },
        ],
      );
      await fixture.mount(tester);

      expect(find.byKey(const Key('note.metadata')), findsOneWidget);
      expect(find.textContaining('Projects'), findsOneWidget);
      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note.move')), findsOneWidget);
      expect(find.byKey(const Key('note.delete')), findsOneWidget);
      await tester.tap(find.byKey(const Key('note.details')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note.tags.chip.work')), findsOneWidget);
      expect(find.byKey(const Key('note.backlinks.item.02H')), findsOneWidget);
      expect(fixture.puts, isEmpty);
    },
  );

  testWidgets(
    'backlink navigation flushes the draft before releasing the lock',
    (tester) async {
      final pending = Completer<http.Response>();
      final fixture = _Fixture(
        backlinks: [
          {'id': '02H', 'title': 'Linked note', 'snippet': ''},
        ],
        onSave: (_) => pending.future,
      );
      String? opened;
      await fixture.mount(tester, onOpenNote: (id) => opened = id);
      fixture.controller.setEditContent('Unsaved Markdown');
      await tester.pump();
      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.backlinks.item.02H')));
      await tester.pump();
      await tester.pump();

      expect(opened, isNull);
      expect(fixture.releases, 0);
      pending.complete(
        _response(_note(content: 'Unsaved Markdown', version: 2)),
      );
      await tester.pumpAndSettle();

      expect(opened, '02H');
      expect(fixture.releases, 1);
      expect(fixture.controller.value.isDirty, isFalse);
      expect(fixture.controller.value.mode, NoteMode.viewing);
    },
  );

  testWidgets('tag navigation keeps the note open when its draft cannot save', (
    tester,
  ) async {
    final fixture = _Fixture(
      tags: ['work'],
      onSave: (_) async =>
          _response({'error': 'internal', 'message': 'offline'}, status: 500),
    );
    String? selected;
    await fixture.mount(tester, onTagTap: (tag) => selected = tag);
    fixture.controller.setEditContent('Keep this draft');
    await tester.pump();
    await tester.tap(find.byKey(const Key('note.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.tags.chip.work')));
    await tester.pumpAndSettle();

    expect(selected, isNull);
    expect(fixture.releases, 0);
    expect(fixture.controller.value.editContent, 'Keep this draft');
    expect(fixture.controller.value.mode, NoteMode.editing);
  });

  testWidgets('moving an edited note saves then moves and resumes editing', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.mount(tester);
    fixture.controller.setEditContent('Draft before move');
    await tester.pump();
    await tester.tap(find.byKey(const Key('note.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.move')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Projects/Alpha');
    await tester.tap(find.byKey(const Key('note.move.confirm')));
    await tester.pumpAndSettle();

    expect(fixture.puts, hasLength(2));
    expect(jsonDecode(fixture.puts.first.body)['content'], 'Draft before move');
    expect(jsonDecode(fixture.puts.last.body)['path'], 'Projects/Alpha');
    expect(fixture.puts.last.headers['if-match'], '2');
    expect(fixture.releases, 1);
    expect(fixture.acquisitions, 2);
    expect(fixture.controller.value.mode, NoteMode.editing);
    expect(fixture.controller.value.note!.path, 'Projects/Alpha');
    expect(fixture.controller.value.editContent, 'Draft before move');
  });

  testWidgets('move does not discard a draft when its flush fails', (
    tester,
  ) async {
    final fixture = _Fixture(
      onSave: (_) async =>
          _response({'error': 'internal', 'message': 'offline'}, status: 500),
    );
    await fixture.mount(tester);
    fixture.controller.setEditContent('Keep this draft');
    await tester.pump();
    await tester.tap(find.byKey(const Key('note.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.move')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Projects/Alpha');
    await tester.tap(find.byKey(const Key('note.move.confirm')));
    await tester.pumpAndSettle();

    expect(fixture.puts, hasLength(1));
    expect(jsonDecode(fixture.puts.single.body).containsKey('path'), isFalse);
    expect(fixture.releases, 0);
    expect(fixture.controller.value.editContent, 'Keep this draft');
    expect(fixture.controller.value.mode, NoteMode.editing);
  });

  testWidgets('system back releases the lock even when the editor is clean', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.mount(tester, asRoute: true);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(fixture.releases, 1);
    expect(find.byType(NoteScreen), findsNothing);
  });
}

http.Response _response(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status);
Map<String, Object?> _note({String content = 'First', int version = 1}) => {
  'id': '01H',
  'title': 'Existing',
  'content': content,
  'version': version,
  'path': '',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'tags': <String>[],
};
Map<String, Object?> _lock(String holder) => {
  'holder': holder,
  'expires_at': '2099-01-01T00:00:00Z',
};

class _Fixture {
  _Fixture({
    this.content = 'First',
    this.onSave,
    this.blockFirstAcquire = false,
    this.path = '',
    this.tags = const [],
    this.backlinks = const [],
  });
  final String content;
  final Future<http.Response> Function(http.Request)? onSave;
  final bool blockFirstAcquire;
  final String path;
  final List<String> tags;
  final List<Map<String, Object?>> backlinks;
  int releases = 0;
  late Map<String, Object?> currentNote;
  int reads = 0;
  int acquisitions = 0;
  final puts = <http.Request>[];
  late NoteController controller;

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onClose,
    ValueChanged<String>? onOpenNote,
    ValueChanged<String>? onTagTap,
    bool asRoute = false,
  }) async {
    currentNote = {..._note(content: content), 'path': path, 'tags': tags};
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/notes/01H') {
        reads++;
        return _response(currentNote);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
        acquisitions++;
        if (blockFirstAcquire && acquisitions == 1) {
          return _response({
            'error': 'locked',
            'lock': _lock('bob'),
          }, status: 423);
        }
        return _response(_lock('tester'));
      }
      if (request.method == 'DELETE' && request.url.path.endsWith('/lock')) {
        releases++;
        return http.Response('', 204);
      }
      if (request.method == 'PUT' && request.url.path == '/notes/01H') {
        puts.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final response =
            await (onSave?.call(request) ??
                Future.value(
                  _response({
                    ...currentNote,
                    ...body,
                    'version': (currentNote['version'] as int) + 1,
                  }),
                ));
        if (response.statusCode == 200) {
          currentNote = Map<String, Object?>.from(
            jsonDecode(response.body) as Map,
          );
        }
        return response;
      }
      if (request.url.path.endsWith('/backlinks')) {
        return _response({'items': backlinks});
      }
      return _response({'items': <Object>[]});
    });
    controller = NoteController(
      api: RobotNotesClient(
        config: const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'test-key',
          actor: 'tester',
        ),
        httpClient: client,
      ),
      noteId: '01H',
      actor: 'tester',
      scheduler: (_) => Completer<void>().future,
      autosaveScheduler: (_) => Completer<void>().future,
    );
    addTearDown(controller.dispose);
    Widget screen(BuildContext context) => NoteScreen(
      controller: controller,
      onClose: onClose ?? (asRoute ? () => Navigator.of(context).pop() : null),
      onOpenNote: onOpenNote,
      onTagTap: onTagTap,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: asRoute
            ? const Scaffold(body: Text('Notes list'))
            : Builder(builder: screen),
      ),
    );
    if (asRoute) {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(builder: screen)));
    }
    await tester.pumpAndSettle();
  }
}
