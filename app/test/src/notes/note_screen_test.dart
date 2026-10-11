import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/notes/block_note_editor.dart';
import 'package:adaptive_super_editor/adaptive_super_editor.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:app/src/widgets/status_strip.dart';
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:material_ui/material_ui.dart';
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
  String path = '',
  List<String> tags = const <String>[],
  String updatedAt = _now,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'content': content,
  'version': version,
  'path': path,
  'created_at': _now,
  'updated_at': updatedAt,
  'tags': tags,
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

/// Opens a [NoteScreen], acquires its lock, and selects Markdown source.
/// [startEditing] leaves new notes in Blocks to verify title focus. [onLock] answers the
/// `POST /notes/{id}/lock` (granted by default); [onSave] answers the
/// `PUT /notes/{id}` the save button sends.
Future<NoteController> _pumpEditor(
  WidgetTester tester, {
  http.Response Function(http.Request)? onLock,
  http.Response Function(http.Request)? onSave,
  http.Response Function(http.Request)? onSearch,
  ValueChanged<String>? onOpenNote,
  bool startEditing = false,
  bool sourceMode = true,
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
    if (request.method == 'GET' && request.url.path == '/search') {
      return onSearch?.call(request) ??
          http.Response(
            jsonEncode(<String, Object?>{'items': <Object?>[]}),
            200,
          );
    }
    return http.Response('unexpected', 500);
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final ctrl = NoteController(
    api: api,
    noteId: '01H',
    actor: 'cedric',
    scheduler: (_) => Completer<void>().future,
    // Autosave firing is exercised at the controller level
    // (note_controller_test.dart); leaving it un-gated here would leave a
    // stray real 2-second timer running behind every widget test that
    // types into the editor.
    autosaveScheduler: (_) => Completer<void>().future,
  );
  addTearDown(ctrl.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: NoteScreen(
        controller: ctrl,
        startEditing: startEditing,
        onOpenNote: onOpenNote,
        linkAutocompleteScheduler: (_) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!startEditing && sourceMode && ctrl.value.mode == NoteMode.editing) {
    await _showSource(tester);
  }
  return ctrl;
}

Future<void> _showSource(WidgetTester tester) async {
  if (find.byKey(_contentField).evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const Key('note.menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('note.source')));
  await tester.pumpAndSettle();
}

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

/// Opens a note whose initial automatic lock attempt is refused.
/// [backlinksItems] answers `GET /notes/01H/backlinks` (empty by default).
/// Later lock attempts succeed so retry interactions can enter Blocks.
Future<void> _pumpViewer(
  WidgetTester tester, {
  required String content,
  String title = 'hello',
  Map<String, Object?> properties = const {},
  Brightness brightness = Brightness.light,
  double textScale = 1,
  List<String> tags = const <String>[],
  String path = '',
  int version = 1,
  String updatedAt = _now,
  List<Object?>? backlinksItems,
  ValueChanged<String>? onOpenNote,
  ValueChanged<String>? onTagTap,
  NotePresentation presentation = NotePresentation.page,
}) async {
  var lockAttempts = 0;
  final mock = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/notes/01H/backlinks') {
      return http.Response(
        jsonEncode(<String, Object?>{'items': backlinksItems ?? <Object?>[]}),
        200,
      );
    }
    if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
      lockAttempts++;
      if (lockAttempts == 1) {
        return http.Response(
          jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        );
      }
      return http.Response(jsonEncode(_lockJson()), 200);
    }
    return http.Response(
      jsonEncode(<String, Object?>{
        ..._noteJson(
          title: title,
          content: content,
          tags: tags,
          path: path,
          version: version,
          updatedAt: updatedAt,
        ),
        'properties': properties,
      }),
      200,
    );
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final ctrl = NoteController(
    api: api,
    noteId: '01H',
    actor: 'cedric',
    scheduler: (_) => Completer<void>().future,
    autosaveScheduler: (_) => Completer<void>().future,
  );
  addTearDown(ctrl.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: NoteScreen(
        controller: ctrl,
        onOpenNote: onOpenNote,
        onTagTap: onTagTap,
        presentation: presentation,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Sizes the test window to [width] x [height] logical pixels for the rest
/// of the test.
void _setWindow(WidgetTester tester, double width, {double height = 800}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Two quick taps on [finder], close enough together to register as a
/// double tap.
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a refused automatic lock keeps the read-only note available', (
    tester,
  ) async {
    await _pumpViewer(tester, content: 'body text');

    expect(find.byKey(const Key('note.body')), findsOneWidget);
    expect(find.text('body text'), findsOneWidget);
    expect(find.byKey(const Key('note.edit')), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Edit'), findsOneWidget);
  });

  testWidgets(
    'roomy reader labels Edit and scrolls properties with the title',
    (tester) async {
      _setWindow(tester, 1200);
      await _pumpViewer(
        tester,
        content: 'A note body',
        properties: {'custom': 'value'},
      );

      expect(
        tester.widget(find.byKey(const Key('note.edit'))),
        isA<OutlinedButton>(),
      );
      final scroll = find.byKey(const Key('note.scroll'));
      for (final key in ['note.title', 'note.metadata', 'note.propertyPanel']) {
        expect(
          find.ancestor(of: find.byKey(Key(key)), matching: scroll),
          findsOneWidget,
        );
      }
      expect(
        tester.getTopLeft(find.byKey(const Key('note.title'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('note.metadata'))).dy),
      );
      await tester.tap(find.byKey(const Key('note.propertyPanel.toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.edit')));
      await tester.pumpAndSettle();
      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(
        find.byKey(const Key('note.propertyPanel.undeclared.custom')),
        findsNothing,
        reason: 'the property panel retains its state when editing starts',
      );
    },
  );

  testWidgets('compact dark reader wraps long titles and enlarged text', (
    tester,
  ) async {
    _setWindow(tester, 360);
    await _pumpViewer(
      tester,
      title: 'A longer note title that remains readable on a small display',
      content: 'A note body',
      properties: {'A longer property label': 'A longer property value'},
      brightness: Brightness.dark,
      textScale: 2,
    );

    expect(
      tester.widget(find.byKey(const Key('note.edit'))),
      isA<IconButton>(),
    );
    expect(find.byKey(const Key('note.title')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('note.body')), 160);
    expect(find.byKey(const Key('note.body')).hitTestable(), findsOneWidget);
  });

  group('presentation', () {
    testWidgets('page shows a back arrow as the leading button', (
      tester,
    ) async {
      await _pumpViewer(tester, content: 'hello');

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect(button.tooltip, 'Back');
      expect((button.icon as Icon).icon, Icons.arrow_back);
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('pane shows a close button as the leading button', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        content: 'hello',
        presentation: NotePresentation.pane,
      );

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note.close')),
      );
      expect(button.tooltip, 'Close');
      expect((button.icon as Icon).icon, Icons.close);
      expect(find.byTooltip('Back'), findsNothing);
    });
  });

  group('reading column', () {
    testWidgets(
      'metadata, body, tags, and backlinks share one scrollable and one '
      'left edge',
      (tester) async {
        _setWindow(tester, 1400);
        await _pumpViewer(
          tester,
          content: 'hello',
          tags: const ['urgent'],
          backlinksItems: [
            {'id': '02H', 'title': 'Referencing note', 'snippet': 's'},
          ],
        );

        final scroll = find.byKey(const Key('note.scroll'));
        expect(scroll, findsOneWidget);
        expect(tester.widget(scroll), isA<SingleChildScrollView>());
        final metadata = find.byKey(const Key('note.metadata'));
        final body = find.byKey(const Key('note.body'));
        final tags = find.byKey(const Key('note.tags'));
        final backlinks = find.byKey(const Key('note.backlinks'));
        for (final part in [metadata, body, tags, backlinks]) {
          expect(
            find.ancestor(of: part, matching: scroll),
            findsOneWidget,
            reason: 'every section scrolls with the body',
          );
        }

        final left = tester.getTopLeft(body).dx;
        expect(tester.getTopLeft(metadata).dx, left);
        expect(tester.getTopLeft(tags).dx, left);
        expect(tester.getTopLeft(backlinks).dx, left);
        // Centered, not flush left, on a wide window.
        expect(left, greaterThan(100));
        expect(tester.getSize(body).width, lessThanOrEqualTo(760));
      },
    );

    testWidgets('a long body scrolls the backlinks into view', (tester) async {
      _setWindow(tester, 800, height: 400);
      await _pumpViewer(
        tester,
        content: List.generate(60, (i) => 'line $i').join('\n\n'),
        backlinksItems: [
          {'id': '02H', 'title': 'Referencing note', 'snippet': 's'},
        ],
      );

      final item = find.byKey(const Key('note.backlinks.item.02H'));
      expect(item.hitTestable(), findsNothing);
      await tester.scrollUntilVisible(
        item,
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('note.scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();

      expect(item.hitTestable(), findsOneWidget);
    });
  });

  group('entering edit mode', () {
    testWidgets('double-tapping the body starts editing', (tester) async {
      await _pumpViewer(tester, content: 'hello');
      expect(find.byKey(_titleField), findsNothing);

      await _doubleTap(tester, find.byKey(const Key('note.body')));

      expect(find.byKey(_titleField), findsOneWidget);
      expect(find.byType(BlockNoteEditor), findsOneWidget);
    });

    testWidgets('Cmd+E starts editing', (tester) async {
      await _pumpViewer(tester, content: 'hello');
      await tester.tap(find.byKey(const Key('note.body')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(find.byType(BlockNoteEditor), findsOneWidget);
    });

    testWidgets('Ctrl+E starts editing', (tester) async {
      await _pumpViewer(tester, content: 'hello');
      await tester.tap(find.byKey(const Key('note.body')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.byType(BlockNoteEditor), findsOneWidget);
    });
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

  group('metadata line', () {
    testWidgets('shows the folder path, version, and a relative time', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        content: 'hello',
        path: 'Personal/Trip Planning',
        version: 4,
        updatedAt: _now,
      );

      expect(find.textContaining('Personal/Trip Planning'), findsOneWidget);
      expect(find.textContaining('v4'), findsOneWidget);
      // `_now` (2025-01-01) is more than a week before "real now", so the
      // relative-time fallback renders as this local absolute date.
      final t = DateTime.parse(_now).toLocal();
      final expectedDate =
          '${t.year}-${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}';
      expect(find.textContaining(expectedDate), findsOneWidget);
    });

    testWidgets('omits the path segment for a root note', (tester) async {
      await _pumpViewer(tester, content: 'hello', version: 2);

      expect(find.byKey(const Key('note.metadata')), findsOneWidget);
      expect(find.textContaining('v2'), findsOneWidget);
    });
  });

  group('reading column width', () {
    testWidgets('clamps the body to a max width on a wide window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pumpViewer(tester, content: 'hello');

      final width = tester.getSize(find.byKey(const Key('note.body'))).width;
      expect(width, lessThanOrEqualTo(760));
    });
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

  testWidgets(
    'opening acquires the lock and source stays explicitly available',
    (tester) async {
      var locks = 0;
      await _pumpEditor(
        tester,
        sourceMode: false,
        onLock: (_) {
          locks++;
          return http.Response(jsonEncode(_lockJson()), 200);
        },
      );
      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(
        tester
            .widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor))
            .readOnly,
        isFalse,
      );
      expect(find.byKey(_contentField), findsNothing);
      expect(locks, 1);
      await _showSource(tester);
      expect(locks, 1);

      expect(find.byKey(_titleField), findsOneWidget);
      expect(find.byKey(_contentField), findsOneWidget);
      expect(find.byKey(const Key('note.save')), findsOneWidget);
    },
  );

  group('editor fields', () {
    testWidgets('are document-style: no outline border, hint text only', (
      tester,
    ) async {
      await _pumpEditor(tester);

      final title = tester.widget<TextField>(find.byKey(_titleField));
      expect(title.decoration?.border, InputBorder.none);
      expect(title.decoration?.enabledBorder, InputBorder.none);
      expect(title.decoration?.focusedBorder, InputBorder.none);
      expect(title.decoration?.disabledBorder, InputBorder.none);
      expect(title.decoration?.filled, isFalse);
      expect(title.decoration?.labelText, isNull);
      expect(title.decoration?.hintText, 'Title');

      final content = tester.widget<TextField>(find.byKey(_contentField));
      expect(content.decoration?.border, InputBorder.none);
      expect(content.decoration?.enabledBorder, InputBorder.none);
      expect(content.decoration?.focusedBorder, InputBorder.none);
      expect(content.decoration?.disabledBorder, InputBorder.none);
      expect(content.decoration?.filled, isFalse);
      expect(content.decoration?.labelText, isNull);
      expect(content.decoration?.hintText, 'Start writing…');
    });

    testWidgets('the title is set in the headline style', (tester) async {
      await _pumpEditor(tester);

      final title = tester.widget<TextField>(find.byKey(_titleField));
      final headline = Theme.of(tester.element(find.byKey(_titleField)))
          .textTheme
          .headlineSmall;
      expect(title.style?.fontSize, headline?.fontSize);
    });
  });

  group('property panel', () {
    testWidgets(
      'editing a property in the panel patches it without disturbing the '
      'body buffer, and the next save uses the returned version',
      (tester) async {
        var propertiesPatched = 0;
        http.Request? lastPut;
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(
              jsonEncode(<String, Object?>{
                ..._noteJson(),
                'properties': <String, Object?>{'status': 'todo'},
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'PATCH' &&
              request.url.path == '/notes/01H/properties') {
            propertiesPatched += 1;
            return http.Response(
              jsonEncode(<String, Object?>{
                ..._noteJson(version: 2),
                'properties': <String, Object?>{'status': 'done'},
              }),
              200,
            );
          }
          if (request.method == 'PUT' && request.url.path == '/notes/01H') {
            lastPut = request;
            return http.Response(jsonEncode(_noteJson(version: 3)), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/notes/01H/backlinks') {
            return http.Response(
              jsonEncode(<String, Object?>{'items': <Object?>[]}),
              200,
            );
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          scheduler: (_) => Completer<void>().future,
          autosaveScheduler: (_) => Completer<void>().future,
        );
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(
          MaterialApp(home: NoteScreen(controller: ctrl)),
        );
        await tester.pumpAndSettle();
        await _showSource(tester);

        expect(
          find.byKey(const Key('note.propertyPanel.undeclared.status')),
          findsOneWidget,
        );

        await tester.enterText(find.byKey(_contentField), 'edited body');

        // `status` here is undeclared (no covering definition), so it
        // renders read-only in the panel — the property editor widgets
        // that drive a real commit are covered by
        // note_property_panel_test.dart. This asserts the screen's wiring
        // of `NoteController.patchProperty` (design.md's queue) leaves the
        // body buffer untouched and the next save uses the patch's
        // returned version.
        await ctrl.patchProperty(set: {'status': 'done'});
        await tester.pumpAndSettle();

        expect(propertiesPatched, 1);
        expect(_fieldController(tester, _contentField).text, 'edited body');
        expect(ctrl.value.mode, NoteMode.editing);

        await tester.tap(find.byKey(const Key('note.save')));
        await tester.pumpAndSettle();

        expect(lastPut, isNotNull);
        expect(lastPut!.headers['If-Match'], '2');
      },
    );
  });

  group('database embeds', () {
    testWidgets(
      'a resolvable embed renders in Blocks and preserves its source',
      (tester) async {
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(
              jsonEncode(_noteJson(content: '![[Projects]]')),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'GET' && request.url.path == '/databases/db1') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'id': 'db1',
                'title': 'Projects',
                'path': '',
                'version': 1,
                'source': <String, Object?>{
                  'folder': '',
                  'include_subfolders': true,
                },
                'properties': <String, Object?>{},
                'views': <Object?>[
                  <String, Object?>{'name': 'All', 'type': 'table'},
                ],
                'created_at': _now,
                'updated_at': _now,
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/databases/db1/query') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'items': <Object?>[
                  <String, Object?>{
                    'id': 'row1',
                    'title': 'Ship it',
                    'path': '',
                    'version': 1,
                    'created_at': _now,
                    'updated_at': _now,
                    'tags': <String>[],
                    'properties': <String, Object?>{},
                    'invalid': <String>[],
                  },
                ],
                'next_cursor': null,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/notes/01H/backlinks') {
            return http.Response(
              jsonEncode(<String, Object?>{'items': <Object?>[]}),
              200,
            );
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final databases = DatabasesController(api: api);
        databases.value = databases.value.copyWith(
          items: [
            DatabaseSummary.fromJson(const <String, Object?>{
              'id': 'db1',
              'title': 'Projects',
              'path': '',
              'source': <String, Object?>{
                'folder': '',
                'include_subfolders': true,
              },
              'row_count': 1,
            }),
          ],
        );
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          scheduler: (_) => Completer<void>().future,
          autosaveScheduler: (_) => Completer<void>().future,
        );
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: NoteScreen(controller: ctrl, databases: databases),
          ),
        );
        await tester.pumpAndSettle();

        // The opaque block delegates existing embeds to the database renderer.
        expect(find.byKey(const Key('database.embed.title')), findsOneWidget);
        expect(find.text('Ship it'), findsOneWidget);
        expect(find.textContaining('![[Projects]]'), findsNothing);

        // Source mode keeps the literal embed syntax.
        await _showSource(tester);
        expect(_fieldController(tester, _contentField).text, '![[Projects]]');
        expect(find.byKey(const Key('note.editor.preview')), findsNothing);
        expect(find.byKey(const Key('database.embed.title')), findsNothing);
      },
    );
  });

  group('Markdown source pane', () {
    for (final size in [
      const Size(1200, 800),
      const Size(390, 844),
      const Size(844, 390),
    ]) {
      testWidgets('uses one full-width pane at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pumpEditor(tester);

        expect(find.byKey(const Key('note.editor.preview')), findsNothing);
        expect(find.byKey(const Key('note.toolbar.preview')), findsNothing);
        expect(find.byKey(_contentField), findsOneWidget);
        final editor = tester.getRect(find.byKey(_contentField));
        expect(editor.width, greaterThan(size.width - 80));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('formatting stays available without a preview toggle', (
      tester,
    ) async {
      _setWindow(tester, 320);
      await _pumpEditor(tester);
      expect(find.byKey(const Key('note.toolbar.link')), findsOneWidget);
      expect(find.byKey(const Key('note.toolbar.preview')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('formatting toolbar', () {
    testWidgets('bold wraps the selected text', (tester) async {
      await _pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(_contentField));
      field.controller!.value = const TextEditingValue(
        text: 'world',
        selection: TextSelection(baseOffset: 0, extentOffset: 5),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('note.toolbar.bold')));
      await tester.pump();

      expect(field.controller!.text, '**world**');
    });

    testWidgets('heading prefixes the current line', (tester) async {
      await _pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(_contentField));
      field.controller!.value = const TextEditingValue(
        text: 'world',
        selection: TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('note.toolbar.heading')));
      await tester.pump();

      expect(field.controller!.text, '# world');
    });

    testWidgets('link inserts a markdown link template', (tester) async {
      await _pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(_contentField));
      field.controller!.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('note.toolbar.link')));
      await tester.pump();

      expect(field.controller!.text, '[title](url)');
    });
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

    await _showSource(tester);
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
      if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
        return http.Response(
          jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        );
      }
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
    var puts = 0;

    setUp(() {
      lockReleases = 0;
      closed = false;
      puts = 0;
    });

    /// [onPut] answers `PUT /notes/01H` when supplied; otherwise the mock
    /// returns 500 for it.
    NoteController controller({http.Response Function(http.Request)? onPut}) {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'DELETE' && path == '/notes/01H/lock') {
          lockReleases += 1;
          return http.Response('', 204);
        }
        if (request.method == 'PUT' && path == '/notes/01H') {
          puts += 1;
          return onPut?.call(request) ?? http.Response('unexpected', 500);
        }
        return http.Response('unexpected', 500);
      });
      final ctrl = NoteController(
        api: RobotNotesClient(config: _config, httpClient: mock),
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
        autosaveScheduler: (_) => Completer<void>().future,
      );
      addTearDown(ctrl.dispose);
      return ctrl;
    }

    Future<void> enterEditMode(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await _showSource(tester);
    }

    Future<NoteController> pumpEditing(
      WidgetTester tester, {
      http.Response Function(http.Request)? onPut,
    }) async {
      final ctrl = controller(onPut: onPut);
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

    testWidgets('without edits closes immediately, with no save', (
      tester,
    ) async {
      final ctrl = await pumpEditing(tester);

      await tapClose(tester);

      expect(puts, 0);
      expect(ctrl.value.mode, NoteMode.viewing);
      expect(lockReleases, 1);
      expect(closed, isTrue);
    });

    testWidgets('with a pending edit, flushes a save and closes', (
      tester,
    ) async {
      final ctrl = await pumpEditing(
        tester,
        onPut: (request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              _noteJson(version: 2, content: body['content'] as String),
            ),
            200,
          );
        },
      );
      await editContent(tester);

      await tapClose(tester);

      expect(puts, 1);
      expect(find.text('Discard changes?'), findsNothing);
      expect(ctrl.value.mode, NoteMode.viewing);
      expect(lockReleases, 1);
      expect(closed, isTrue);
    });

    testWidgets('a flush that hits a conflict keeps the note open', (
      tester,
    ) async {
      final ctrl = await pumpEditing(
        tester,
        onPut: (_) => http.Response(
          jsonEncode(<String, Object?>{
            'error': 'version_conflict',
            'current': _noteJson(version: 7, content: 'server'),
          }),
          409,
        ),
      );
      await editContent(tester);

      await tapClose(tester);

      expect(puts, 1);
      expect(ctrl.value.mode, NoteMode.conflict);
      expect(find.byKey(const Key('note.banner.conflict')), findsOneWidget);
      expect(lockReleases, 0);
      expect(closed, isFalse);
    });

    testWidgets('a flush that hits a transient error keeps the note open', (
      tester,
    ) async {
      final ctrl = await pumpEditing(
        tester,
        onPut: (_) => http.Response(jsonEncode({'message': 'db locked'}), 500),
      );
      await editContent(tester);

      await tapClose(tester);

      expect(puts, 1);
      expect(find.text('Could not save: db locked'), findsOneWidget);
      expect(ctrl.value.mode, NoteMode.editing);
      expect(ctrl.value.editContent, 'world, edited');
      expect(lockReleases, 0);
      expect(closed, isFalse);
    });

    testWidgets(
      'a flush that loses the lock retains the draft when close is cancelled',
      (tester) async {
        final ctrl = await pumpEditing(
          tester,
          onPut: (_) => http.Response(
            jsonEncode({
              'message': 'locked',
              'lock': _lockJson(holder: 'alice'),
            }),
            423,
          ),
        );
        await editContent(tester);

        await tapClose(tester);

        expect(puts, 1);
        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.lock?.holder, 'alice');
        // The lock is no longer ours — no DELETE lock is sent for it.
        expect(lockReleases, 0);
        expect(find.text('Discard and close'), findsOneWidget);
        await tester.tap(find.text('Keep open'));
        await tester.pumpAndSettle();
        expect(_fieldController(tester, _contentField).text, 'world, edited');
        expect(
          tester.widget<TextField>(find.byKey(_contentField)).readOnly,
          isTrue,
        );
        expect(closed, isFalse);
      },
    );

    testWidgets('system back with a pending edit flushes and pops', (
      tester,
    ) async {
      final ctrl = controller(
        onPut: (request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              _noteJson(version: 2, content: body['content'] as String),
            ),
            200,
          );
        },
      );
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

      expect(find.text('Discard changes?'), findsNothing);
      expect(puts, 1);
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

    testWidgets('Escape while dirty flushes a save and closes', (tester) async {
      final ctrl = await _pumpEditor(
        tester,
        onSave: (request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              _noteJson(version: 2, content: body['content'] as String),
            ),
            200,
          );
        },
      );
      await tester.tap(find.byKey(_contentField));
      await tester.enterText(find.byKey(_contentField), 'edited');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(ctrl.value.mode, NoteMode.viewing);
    });

    testWidgets('Cmd+S while only viewing sends no request and no snackbar', (
      tester,
    ) async {
      var putCalls = 0;
      final mock = MockClient((request) async {
        if (request.method == 'PUT') putCalls += 1;
        if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
          return http.Response(
            jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
            423,
          );
        }
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

    testWidgets('the web save shortcut only saves the top-most note route', (
      tester,
    ) async {
      // The real listener behind `installSaveShortcut` attaches to the
      // browser `window`, not to this widget's place in the Navigator
      // stack, so every mounted NoteScreen's handler fires on the same
      // keypress. Capture each screen's handler instead of relying on a
      // real `keydown` (unreachable from a VM test) to prove the guard in
      // `_saveIfEditing` — not the DOM listener itself — is what keeps a
      // background note from saving.
      final saveHandlers = <String, VoidCallback>{};
      VoidCallback Function(VoidCallback) captureInstall(String id) =>
          (onSave) {
            saveHandlers[id] = onSave;
            return () {};
          };

      var putsForA = 0;
      var putsForB = 0;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            (path == '/notes/01A' || path == '/notes/01B')) {
          return http.Response(
            jsonEncode(_noteJson(id: path.split('/').last)),
            200,
          );
        }
        if (path.endsWith('/lock') &&
            (request.method == 'POST' || request.method == 'PUT')) {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PUT' && path == '/notes/01A') {
          putsForA += 1;
          return http.Response(
            jsonEncode(_noteJson(id: '01A', version: 2)),
            200,
          );
        }
        if (request.method == 'PUT' && path == '/notes/01B') {
          putsForB += 1;
          return http.Response(
            jsonEncode(_noteJson(id: '01B', version: 2)),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrlA = NoteController(
        api: api,
        noteId: '01A',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
      );
      final ctrlB = NoteController(
        api: api,
        noteId: '01B',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
      );
      addTearDown(ctrlA.dispose);
      addTearDown(ctrlB.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteScreen(
            controller: ctrlA,
            startEditing: true,
            installSaveShortcut: captureInstall('A'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => NoteScreen(
              controller: ctrlB,
              startEditing: true,
              installSaveShortcut: captureInstall('B'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(saveHandlers.keys, containsAll(<String>['A', 'B']));

      saveHandlers['A']!();
      await tester.pumpAndSettle();
      expect(putsForA, 0, reason: 'the background note must not save');

      saveHandlers['B']!();
      await tester.pumpAndSettle();
      expect(putsForB, 1, reason: 'the current note saves as usual');
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

    group('editing status', () {
      testWidgets('shows "Unsaved changes" right after an edit', (
        tester,
      ) async {
        await _pumpEditor(tester);

        await tester.enterText(find.byKey(_contentField), 'edited');
        await tester.pump();

        expect(find.byKey(const Key('note.editingStatus')), findsOneWidget);
        expect(find.text('Unsaved changes'), findsOneWidget);
      });

      testWidgets('shows "Saving…" while a save is in flight', (tester) async {
        final saveGate = Completer<http.Response>();
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'PUT' && request.url.path == '/notes/01H') {
            return saveGate.future;
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          scheduler: (_) => Completer<void>().future,
          autosaveScheduler: (_) => Completer<void>().future,
        );
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: NoteScreen(
              controller: ctrl,
              linkAutocompleteScheduler: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _showSource(tester);

        await tester.enterText(find.byKey(_contentField), 'edited');
        await tester.tap(find.byKey(const Key('note.save')));
        await tester.pump();

        expect(find.text('Saving…'), findsOneWidget);

        // Let the pending request settle so the test doesn't leak it.
        saveGate.complete(
          http.Response(jsonEncode(_noteJson(content: 'edited')), 200),
        );
        await tester.pumpAndSettle();
      });

      testWidgets('shows "Autosaved" with the last-saved time after a save', (
        tester,
      ) async {
        await _pumpEditor(
          tester,
          onSave: (request) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode(
                _noteJson(version: 2, content: body['content'] as String),
              ),
              200,
            );
          },
        );

        await tester.enterText(find.byKey(_contentField), 'edited');
        await tester.tap(find.byKey(const Key('note.save')));
        await tester.pumpAndSettle();

        final saved = formatLockExpiry(
          DateTime.parse('2025-01-01T00:00:00.000Z'),
        );
        expect(find.text('Autosaved $saved'), findsOneWidget);
      });

      testWidgets('shows an avatar for who is editing', (tester) async {
        await _pumpEditor(tester);

        expect(
          find.descendant(
            of: find.byKey(const Key('note.editingStatus')),
            matching: find.byType(CircleAvatar),
          ),
          findsOneWidget,
        );
      });
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
    await _showSource(tester);
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

  testWidgets('presence indicator shows names for three or fewer viewers', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
        return http.Response(
          jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        );
      }
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
        PresenceEvent(noteId: '01H', viewers: <String>['cedric', 'agent-1']),
      ),
    );
    await tester.pumpAndSettle();

    final presence = find.byKey(const Key('note.presence'));
    expect(presence, findsOneWidget);
    // One initial per viewer, no "+N" overflow.
    expect(
      find.descendant(of: presence, matching: find.byType(CircleAvatar)),
      findsNWidgets(2),
    );
    expect(find.descendant(of: presence, matching: find.text('C')), findsOne);
    expect(find.descendant(of: presence, matching: find.text('A')), findsOne);
    expect(find.textContaining('+'), findsNothing);
    final tooltip = tester.widget<Tooltip>(
      find.descendant(of: presence, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, 'cedric, agent-1');
    final semantics = tester.widget<Semantics>(
      find.descendant(of: presence, matching: find.byType(Semantics)).first,
    );
    expect(semantics.properties.label, 'Viewers: cedric, agent-1');
  });

  testWidgets('presence avatars are readable by assistive technology', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
        return http.Response(
          jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        );
      }
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
        PresenceEvent(noteId: '01H', viewers: <String>['agent-1']),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Viewer: agent-1'), findsOneWidget);
    handle.dispose();
  });

  testWidgets(
    'presence indicator shows a count with a tooltip beyond three viewers',
    (tester) async {
      final mock = MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
          return http.Response(
            jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
            423,
          );
        }
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
          PresenceEvent(
            noteId: '01H',
            viewers: <String>['cedric', 'alice', 'bob', 'agent-1'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final presence = find.byKey(const Key('note.presence'));
      // Three initials plus one "+N" overflow avatar.
      expect(
        find.descendant(of: presence, matching: find.byType(CircleAvatar)),
        findsNWidgets(4),
      );
      expect(
        find.descendant(of: presence, matching: find.text('+1')),
        findsOne,
      );
      expect(find.text('4 viewers'), findsNothing);
      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: presence, matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, 'cedric, alice, bob, agent-1');
      final semantics = tester.widget<Semantics>(
        find.descendant(of: presence, matching: find.byType(Semantics)).first,
      );
      expect(
        semantics.properties.label,
        'Viewers: cedric, alice, bob, agent-1',
      );
    },
  );

  testWidgets('lock event from another holder shows an info banner', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
        return http.Response(
          jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
          423,
        );
      }
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
    final strip = tester.widget<StatusStrip>(
      find.byKey(const Key('note.banner.lock')),
    );
    expect(strip.tone, StatusTone.info);
  });

  testWidgets('losing the lock mid-edit shows a warning strip', (tester) async {
    final events = StreamController<RealtimeEvent>.broadcast();
    addTearDown(events.close);
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
        return http.Response(jsonEncode(_lockJson()), 200);
      }
      return http.Response(jsonEncode(_noteJson()), 200);
    });
    final ctrl = NoteController(
      api: RobotNotesClient(config: _config, httpClient: mock),
      noteId: '01H',
      actor: 'cedric',
      events: events.stream,
      scheduler: (_) => Completer<void>().future,
      autosaveScheduler: (_) => Completer<void>().future,
    );
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(home: NoteScreen(controller: ctrl)));
    await tester.pumpAndSettle();
    await _showSource(tester);
    expect(
      tester
          .widget<StatusStrip>(find.byKey(const Key('note.editingStatus')))
          .tone,
      StatusTone.info,
    );

    await tester.enterText(find.byKey(_contentField), 'retained draft');

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

    final strip = tester.widget<StatusStrip>(
      find.byKey(const Key('note.banner.lockedByOther')),
    );
    expect(strip.tone, StatusTone.warning);
    expect(find.textContaining('alice'), findsOneWidget);
    expect(find.byType(BlockNoteEditor), findsOneWidget);
    expect(_fieldController(tester, _contentField).text, 'retained draft');
    expect(
      tester.widget<TextField>(find.byKey(_contentField)).readOnly,
      isTrue,
    );
  });

  group('delete', () {
    /// Pumps a read-only note, opens the overflow menu, and picks
    /// "Delete note" so the confirm dialog is showing. Records requests in
    /// the returned list; `DELETE /notes/01H` answers with [deleteStatus].
    Future<List<String>> pumpAndOpenDeleteDialog(
      WidgetTester tester, {
      required VoidCallback onClose,
      int deleteStatus = 204,
      bool reducedMotion = false,
    }) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
          return http.Response(
            jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
            423,
          );
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
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

    testWidgets('reduced-motion delete cancels without a request', (
      tester,
    ) async {
      var closed = 0;
      final calls = await pumpAndOpenDeleteDialog(
        tester,
        onClose: () => closed += 1,
        reducedMotion: true,
      );

      final route = ModalRoute.of(
        tester.element(find.byKey(const Key('note.delete.cancel'))),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(find.byKey(const Key('note.delete.cancel')));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(find.text('Delete this note?'), findsNothing);
      expect(closed, 0);
      expect(find.byKey(const Key('note.body')), findsOneWidget);
    }, variant: TargetPlatformVariant.all());
  });

  group('link autocomplete', () {
    testWidgets('typing [[ opens a list filtered by subsequent characters', (
      tester,
    ) async {
      await _pumpEditor(
        tester,
        onSearch: (request) => http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              {
                'id': '02H',
                'title': 'Project Alpha',
                'snippet': 's',
                'rank': 1.0,
                'updated_at': _now,
              },
              {
                'id': '03H',
                'title': 'Project Beta',
                'snippet': 's',
                'rank': 0.5,
                'updated_at': _now,
              },
            ],
          }),
          200,
        ),
      );

      await tester.enterText(find.byKey(_contentField), '[[Proj');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('note.editor.linkSuggestion.Project Alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('note.editor.linkSuggestion.Project Beta')),
        findsOneWidget,
      );
    });

    testWidgets('selecting an entry inserts [[Title]] at the cursor', (
      tester,
    ) async {
      await _pumpEditor(
        tester,
        onSearch: (request) => http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              {
                'id': '02H',
                'title': 'Project Alpha',
                'snippet': 's',
                'rank': 1.0,
                'updated_at': _now,
              },
            ],
          }),
          200,
        ),
      );

      await tester.enterText(find.byKey(_contentField), '[[Proj');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('note.editor.linkSuggestion.Project Alpha')),
      );
      await tester.pumpAndSettle();

      expect(_fieldController(tester, _contentField).text, '[[Project Alpha]]');
    });

    testWidgets(
      'selecting an entry preserves a typed alias as [[Title|Alias]]',
      (tester) async {
        await _pumpEditor(
          tester,
          onSearch: (request) => http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                {
                  'id': '02H',
                  'title': 'Project Alpha',
                  'snippet': 's',
                  'rank': 1.0,
                  'updated_at': _now,
                },
              ],
            }),
            200,
          ),
        );

        await tester.enterText(find.byKey(_contentField), '[[Proj|Alias');
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('note.editor.linkSuggestion.Project Alpha')),
        );
        await tester.pumpAndSettle();

        expect(
          _fieldController(tester, _contentField).text,
          '[[Project Alpha|Alias]]',
        );
      },
    );

    testWidgets('the list closes once the link is closed with ]]', (
      tester,
    ) async {
      await _pumpEditor(
        tester,
        onSearch: (request) => http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              {
                'id': '02H',
                'title': 'Project Alpha',
                'snippet': 's',
                'rank': 1.0,
                'updated_at': _now,
              },
            ],
          }),
          200,
        ),
      );

      await tester.enterText(find.byKey(_contentField), '[[Proj');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('note.editor.linkSuggestion.Project Alpha')),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(_contentField), '[[Project Alpha]]');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('note.editor.linkSuggestion.Project Alpha')),
        findsNothing,
      );
    });
  });

  group('backlinks panel', () {
    testWidgets('lists referencing notes with a snippet', (tester) async {
      await _pumpViewer(
        tester,
        content: 'hello',
        backlinksItems: [
          {'id': '02H', 'title': 'Referencing note', 'snippet': 'a snippet'},
        ],
      );

      expect(find.byKey(const Key('note.backlinks')), findsOneWidget);
      expect(find.text('Referencing note'), findsOneWidget);
      expect(find.text('a snippet'), findsOneWidget);
    });

    testWidgets(
      'shows an empty state rather than an error when there are none',
      (tester) async {
        await _pumpViewer(tester, content: 'hello');

        expect(find.byKey(const Key('note.backlinks')), findsOneWidget);
        expect(find.byKey(const Key('note.backlinks.empty')), findsOneWidget);
      },
    );

    testWidgets(
      'collapses to a compact line instead of a full panel when empty',
      (tester) async {
        await _pumpViewer(tester, content: 'hello');

        // No separate "Backlinks" heading claiming footer space when
        // there's nothing to show — just the compact empty-state line.
        expect(find.text('Backlinks'), findsNothing);
        expect(find.byKey(const Key('note.backlinks.empty')), findsOneWidget);
      },
    );

    testWidgets('shows the "Backlinks" heading when there are entries', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        content: 'hello',
        backlinksItems: [
          {'id': '02H', 'title': 'Referencing note', 'snippet': 'a snippet'},
        ],
      );

      expect(find.text('Backlinks'), findsOneWidget);
    });

    testWidgets('tapping an entry opens that note', (tester) async {
      String? opened;
      await _pumpViewer(
        tester,
        content: 'hello',
        backlinksItems: [
          {'id': '02H', 'title': 'Referencing note', 'snippet': 'a snippet'},
        ],
        onOpenNote: (id) => opened = id,
      );

      await tester.tap(find.byKey(const Key('note.backlinks.item.02H')));
      await tester.pumpAndSettle();

      expect(opened, '02H');
    });
  });

  group('tags', () {
    testWidgets('renders chips for the note\'s computed tags', (tester) async {
      await _pumpViewer(
        tester,
        content: 'hello',
        tags: const ['urgent', 'planning'],
      );

      expect(find.byKey(const Key('note.tags')), findsOneWidget);
      expect(find.text('urgent'), findsOneWidget);
      expect(find.text('planning'), findsOneWidget);
    });

    testWidgets('renders no chip row when the note has no tags', (
      tester,
    ) async {
      await _pumpViewer(tester, content: 'hello');

      expect(find.byKey(const Key('note.tags')), findsNothing);
    });

    testWidgets('tapping a tag chip calls onTagTap with that tag', (
      tester,
    ) async {
      String? tapped;
      await _pumpViewer(
        tester,
        content: 'hello',
        tags: const ['urgent', 'planning'],
        onTagTap: (tag) => tapped = tag,
      );

      await tester.tap(find.text('urgent'));
      await tester.pumpAndSettle();

      expect(tapped, 'urgent');
    });
  });

  group('pull to refresh', () {
    /// Pumps the viewer over a backend whose `GET /notes/01H` answers are
    /// taken from [responses] in order (the last one repeats).
    Future<List<String>> pumpWithResponses(
      WidgetTester tester,
      List<http.Response Function()> responses,
    ) async {
      final calls = <String>[];
      var gets = 0;
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          final i = gets < responses.length ? gets : responses.length - 1;
          gets += 1;
          return responses[i]();
        }
        if (request.url.path == '/notes/01H/backlinks') {
          return http.Response(
            jsonEncode(<String, Object?>{'items': <Object?>[]}),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(
            jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
            423,
          );
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
        autosaveScheduler: (_) => Completer<void>().future,
      );
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NoteScreen(
            controller: ctrl,
            linkAutocompleteScheduler: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      return calls;
    }

    /// Pulls the reading view down far enough to trigger its refresh and
    /// waits for the indicator to run and hide.
    Future<void> pull(WidgetTester tester) async {
      await tester.fling(
        find.byKey(const Key('note.scroll')),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    testWidgets('pulling the reading view down re-fetches the note', (
      tester,
    ) async {
      final calls = await pumpWithResponses(tester, [
        () => http.Response(jsonEncode(_noteJson(content: 'first')), 200),
        () => http.Response(
          jsonEncode(_noteJson(content: 'second', version: 2)),
          200,
        ),
      ]);
      expect(find.text('first'), findsOneWidget);
      expect(find.byKey(const Key('note.refresh')), findsOneWidget);
      expect(calls.where((c) => c == 'GET /notes/01H').length, 1);

      await pull(tester);

      expect(calls.where((c) => c == 'GET /notes/01H').length, 2);
      expect(find.text('second'), findsOneWidget);
      expect(find.text('first'), findsNothing);
      expect(find.textContaining('v2'), findsOneWidget);
    });

    testWidgets('a failed re-fetch keeps the note and reports the failure', (
      tester,
    ) async {
      await pumpWithResponses(tester, [
        () => http.Response(jsonEncode(_noteJson(content: 'kept')), 200),
        () => http.Response(
          jsonEncode(<String, Object?>{'error': 'internal', 'message': 'boom'}),
          500,
        ),
      ]);

      await pull(tester);

      expect(find.text('kept'), findsOneWidget);
      expect(find.textContaining('Could not refresh the note'), findsOneWidget);
    });

    testWidgets('no refresh indicator while editing', (tester) async {
      await _pumpEditor(tester);

      expect(find.byKey(const Key('note.refresh')), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);
    });
  });

  group('move', () {
    /// Pumps a read-only note and opens the move dialog via the overflow
    /// menu. `PUT /notes/01H` answers with [putResponse].
    Future<List<String>> pumpAndOpenMoveDialog(
      WidgetTester tester, {
      required http.Response Function(http.Request) putResponse,
      bool reducedMotion = false,
    }) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/lock')) {
          return http.Response(
            jsonEncode({'error': 'locked', 'lock': _lockJson(holder: 'alice')}),
            423,
          );
        }
        if (request.method == 'PUT' && request.url.path == '/notes/01H') {
          return putResponse(request);
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: NoteScreen(controller: ctrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note.move')));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('confirming sends PUT with the chosen path', (tester) async {
      Map<String, dynamic>? body;
      final calls = await pumpAndOpenMoveDialog(
        tester,
        putResponse: (request) {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_noteJson(version: 2)), 200);
        },
      );
      expect(find.text('Move to folder'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('note.move.input')),
        'Projects/Alpha',
      );
      await tester.tap(find.byKey(const Key('note.move.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('PUT /notes/01H'));
      expect(body?['path'], 'Projects/Alpha');
      expect(find.byKey(const Key('note.body')), findsOneWidget);
    });

    testWidgets(
      'a 409 path_conflict shows a non-destructive error and leaves the '
      'note open',
      (tester) async {
        await pumpAndOpenMoveDialog(
          tester,
          putResponse: (request) => http.Response(
            jsonEncode(<String, Object?>{'error': 'path_conflict'}),
            409,
          ),
        );

        await tester.enterText(
          find.byKey(const Key('note.move.input')),
          'Projects/Alpha',
        );
        await tester.tap(find.byKey(const Key('note.move.confirm')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Projects/Alpha'),
          findsWidgets,
          reason: 'the error names the colliding path',
        );
        expect(find.byKey(const Key('note.body')), findsOneWidget);
      },
    );

    testWidgets(
      '423 shows the existing lock-holder banner and leaves the note open',
      (tester) async {
        await pumpAndOpenMoveDialog(
          tester,
          putResponse: (request) => http.Response(
            jsonEncode(<String, Object?>{
              'error': 'locked',
              'lock': _lockJson(holder: 'alice'),
            }),
            423,
          ),
        );

        await tester.enterText(
          find.byKey(const Key('note.move.input')),
          'Projects/Alpha',
        );
        await tester.tap(find.byKey(const Key('note.move.confirm')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('note.banner.lock')), findsOneWidget);
        expect(find.textContaining('alice'), findsWidgets);
        expect(find.byKey(const Key('note.body')), findsOneWidget);
      },
    );

    testWidgets('reduced-motion move cancels without a request', (
      tester,
    ) async {
      final calls = await pumpAndOpenMoveDialog(
        tester,
        reducedMotion: true,
        putResponse: (request) => http.Response('unexpected', 500),
      );

      final route = ModalRoute.of(
        tester.element(find.byKey(const Key('note.move.input'))),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(find.byKey(const Key('note.move.cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note.move.input')), findsNothing);
      expect(calls, isNot(contains('PUT /notes/01H')));
    }, variant: TargetPlatformVariant.all());
  });
}
