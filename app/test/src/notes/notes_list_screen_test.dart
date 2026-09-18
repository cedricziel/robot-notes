import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/layout/breakpoints.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:flutter/gestures.dart';
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

Map<String, Object?> _metaJson({
  required String id,
  String title = 'note',
  int version = 1,
  String path = '',
  String excerpt = '',
  List<String> tags = const [],
  String updatedAt = _now,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'version': version,
  'path': path,
  'excerpt': excerpt,
  'tags': tags,
  'created_at': _now,
  'updated_at': updatedAt,
};

http.Response _page(List<Object?> items) => http.Response(
  jsonEncode(<String, Object?>{
    'items': items,
    'limit': 50,
    'next_cursor': null,
  }),
  200,
);

/// Drags the sidebar's resize handle by [dx] with a mouse (no touch slop
/// is swallowed, so the panel sees exactly [dx]).
Future<void> _dragHandle(WidgetTester tester, double dx) async {
  final handle = find.byKey(const Key('panel.resizeHandle'));
  final gesture = await tester.startGesture(
    tester.getCenter(handle),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(Offset(dx, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('initial render fetches the first page', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[
        _metaJson(id: '01H', title: 'hello'),
        _metaJson(id: '02H', title: 'world'),
      ]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    // Post-frame callback runs on the next pump; let it complete.
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('world'), findsOneWidget);
  });

  testWidgets('an active tag filter shows a clearable chip', (tester) async {
    // Regression test: selecting a tag via a tag chip used to have no way
    // back — nothing displayed the active filter and nothing cleared it.
    final requestedTags = <String?>[];
    final mock = MockClient((request) async {
      requestedTags.add(request.url.queryParameters['tag']);
      return _page(<Object?>[_metaJson(id: '01H', title: 'hello')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notes.filter.tag')), findsNothing);

    await ctrl.selectTag('urgent');
    await tester.pumpAndSettle();

    expect(find.text('Tag: urgent'), findsOneWidget);

    await tester.tap(find.byKey(const Key('notes.filter.tag.clear')));
    await tester.pumpAndSettle();

    expect(ctrl.value.selectedTag, isNull);
    expect(find.byKey(const Key('notes.filter.tag')), findsNothing);
    expect(requestedTags.last, isNull);
  });

  testWidgets('a supplied sidebar renders beside the list on a wide screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[_metaJson(id: '01H', title: 'hello')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(controller: ctrl, sidebar: const Text('SIDEBAR')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('SIDEBAR'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('a supplied sidebar lives in a drawer on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[_metaJson(id: '01H', title: 'hello')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(controller: ctrl, sidebar: const Text('SIDEBAR')),
      ),
    );
    await tester.pumpAndSettle();

    // Not directly visible until the drawer is opened.
    expect(find.text('SIDEBAR'), findsNothing);

    final scaffoldState = tester.firstState<ScaffoldState>(
      find.byType(Scaffold),
    );
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('SIDEBAR'), findsOneWidget);
  });

  testWidgets('tapping a note tile invokes onNoteTap with the id', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      return _page(<Object?>[_metaJson(id: '01H', title: 'tap me')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    String? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(controller: ctrl, onNoteTap: (id) => tapped = id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.tile.01H')));
    await tester.pump();

    expect(tapped, '01H');
  });

  testWidgets('pull-to-refresh re-fetches the first page', (tester) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[_metaJson(id: '01H', title: 'after-$calls')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    // Drive the controller directly. The RefreshIndicator's onRefresh is
    // bound to this same method, so we exercise the same behavior without
    // needing the gesture machinery.
    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('after-2'), findsOneWidget);
  });

  testWidgets('the wide toolbar refresh action re-fetches the first page', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return _page(<Object?>[_metaJson(id: '01H', title: 'after-$calls')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('shell.refresh')));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('after-2'), findsOneWidget);
  });

  testWidgets('a failed refresh shows a banner and keeps loaded items', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      if (calls == 1) {
        return _page(<Object?>[_metaJson(id: '01H', title: 'still here')]);
      }
      return http.Response(
        jsonEncode(<String, Object?>{'message': 'database is locked'}),
        500,
      );
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notes.error')), findsNothing);

    await ctrl.refresh();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notes.error')), findsOneWidget);
    expect(find.text('database is locked'), findsOneWidget);
    expect(find.text('still here'), findsOneWidget);
  });

  testWidgets('the error banner retry re-fetches and clears the banner', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      if (calls == 1) {
        return http.Response('', 503);
      }
      return _page(<Object?>[_metaJson(id: '01H', title: 'recovered')]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(home: NotesListScreen(controller: ctrl)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notes.error')), findsOneWidget);
    expect(find.text('Could not load notes.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.byKey(const Key('notes.error')), findsNothing);
    expect(find.text('recovered'), findsOneWidget);
  });

  group('note row content', () {
    testWidgets('shows a relative time and no version number', (tester) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[_metaJson(id: '01H')]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      // _now (2025) is well past the one-week relative-time cutoff, so the
      // widget falls back to the absolute timestamp — this still proves
      // the "v1 · " prefix is gone without needing a fake clock.
      final expected = formatNoteTimestamp(DateTime.parse(_now));
      expect(find.text(expected), findsOneWidget);
      expect(find.textContaining('v1'), findsNothing);
    });

    testWidgets('shows the folder path in the metadata line', (tester) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', title: 'Weekend Trip', path: 'Personal/Trip'),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Personal/Trip'), findsOneWidget);
    });

    testWidgets('a very long path does not overflow the row', (tester) async {
      final longPath =
          'Personal/Trip Planning/${'Very Long Folder Name/' * 8}Sub';
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', title: 'Weekend Trip', path: longPath),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final pathText = tester.widget<Text>(
        find.byKey(const Key('notes.tile.01H.path')),
      );
      expect(pathText.maxLines, 1);
      expect(pathText.overflow, TextOverflow.ellipsis);
    });

    testWidgets('does not show a path line for a root note', (tester) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[_metaJson(id: '01H', title: 'Root note')]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.tile.01H.path')), findsNothing);
    });

    testWidgets('shows the excerpt', (tester) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', excerpt: 'Leaving Friday evening'),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Leaving Friday evening'), findsOneWidget);
    });

    testWidgets('shows each tag as a plain "#tag" label, not a Chip', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', tags: ['travel', 'urgent']),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.text('#travel'), findsOneWidget);
      expect(find.text('#urgent'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);
      expect(find.byType(InputChip), findsNothing);

      final theme = Theme.of(tester.element(find.text('#travel')));
      final label = tester.widget<Text>(find.text('#travel'));
      expect(label.style?.fontSize, theme.textTheme.labelSmall?.fontSize);
      expect(label.style?.color, theme.colorScheme.onSurfaceVariant);
    });

    testWidgets('hides the path when the list is scoped to that folder', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', title: 'In Alpha', path: 'Projects/Alpha'),
          _metaJson(id: '02H', title: 'Elsewhere', path: 'Projects/Beta'),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.tile.01H.path')), findsOneWidget);

      await ctrl.selectFolder('Projects/Alpha');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.tile.01H.path')), findsNothing);
      // A note the server returned from a subfolder still shows where it is.
      expect(find.byKey(const Key('notes.tile.02H.path')), findsOneWidget);
    });

    testWidgets('shows no tag labels when the note has no tags', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[_metaJson(id: '01H')]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Chip), findsNothing);
      expect(find.textContaining('#'), findsNothing);
    });

    testWidgets('the row matching selectedNoteId renders selected', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return _page(<Object?>[
          _metaJson(id: '01H', title: 'open'),
          _metaJson(id: '02H', title: 'other'),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(controller: ctrl, selectedNoteId: '01H'),
        ),
      );
      await tester.pumpAndSettle();

      ListTile tile(String id) =>
          tester.widget<ListTile>(find.byKey(Key('notes.tile.$id')));
      expect(tile('01H').selected, isTrue);
      expect(tile('02H').selected, isFalse);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(tile('01H').selected, isFalse);
    });
  });

  group('delete', () {
    testWidgets('long-press opens the menu; confirming deletes the note', (
      tester,
    ) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/notes') {
          return _page(<Object?>[_metaJson(id: '01H', title: 'byebye')]);
        }
        if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
          return http.Response('', 204);
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const Key('notes.tile.01H')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.tile.01H.delete')), findsOneWidget);

      await tester.tap(find.byKey(const Key('notes.tile.01H.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this note?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('byebye'), findsNothing);
      expect(find.text('Note deleted'), findsOneWidget);
    });

    testWidgets('cancelling the confirm dialog sends no request', (
      tester,
    ) async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/notes') {
          return _page(<Object?>[_metaJson(id: '01H', title: 'stays')]);
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const Key('notes.tile.01H')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.tile.01H.delete')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.delete.cancel')));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(find.text('stays'), findsOneWidget);
    });

    testWidgets(
      'hovering a row on a wide screen reveals a delete button that works',
      (tester) async {
        tester.view.physicalSize = const Size(800, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <String>[];
        final mock = MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/notes') {
            return _page(<Object?>[_metaJson(id: '01H', title: 'byebye')]);
          }
          if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
            return http.Response('', 204);
          }
          return http.Response('unexpected: ${request.url.path}', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NotesListController(api: api);
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(
          MaterialApp(home: NotesListScreen(controller: ctrl)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('notes.tile.01H.hoverDelete')),
          findsNothing,
        );

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await tester.pump();
        await gesture.moveTo(
          tester.getCenter(find.byKey(const Key('notes.tile.01H'))),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('notes.tile.01H.hoverDelete')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('notes.tile.01H.hoverDelete')));
        await tester.pumpAndSettle();
        expect(find.text('Delete this note?'), findsOneWidget);

        await tester.tap(find.byKey(const Key('notes.delete.confirm')));
        await tester.pumpAndSettle();

        expect(calls, contains('DELETE /notes/01H'));
        expect(find.text('byebye'), findsNothing);
      },
    );
  });

  group('swipe to delete', () {
    /// Pumps a single-row list whose backend answers `DELETE /notes/01H`
    /// with [deleteResponse] and records every request in [calls].
    Future<NotesListController> pumpRow(
      WidgetTester tester, {
      required List<String> calls,
      http.Response Function()? deleteResponse,
    }) async {
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/notes') {
          return _page(<Object?>[_metaJson(id: '01H', title: 'swiped')]);
        }
        if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
          return deleteResponse?.call() ?? http.Response('', 204);
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      return ctrl;
    }

    const tile = Key('notes.tile.01H');

    testWidgets('swiping a row toward the leading edge asks to confirm; '
        'confirming deletes the note', (tester) async {
      final calls = <String>[];
      await pumpRow(tester, calls: calls);

      // The default 800px test surface: 500px is comfortably past the 40%
      // dismiss threshold.
      await tester.drag(find.byKey(tile), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Delete this note?'), findsOneWidget);
      expect(calls, isNot(contains('DELETE /notes/01H')));

      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swiped'), findsNothing);
      expect(find.text('Note deleted'), findsOneWidget);
    });

    testWidgets('cancelling a swipe springs the row back with no request', (
      tester,
    ) async {
      final calls = <String>[];
      await pumpRow(tester, calls: calls);
      final restingLeft = tester.getTopLeft(find.byKey(tile)).dx;

      await tester.drag(find.byKey(tile), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Delete this note?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('notes.delete.cancel')));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(find.text('swiped'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(tile)).dx, restingLeft);
    });

    testWidgets('a failed delete keeps the row and surfaces the error', (
      tester,
    ) async {
      final calls = <String>[];
      await pumpRow(
        tester,
        calls: calls,
        deleteResponse: () => http.Response(
          jsonEncode(<String, Object?>{
            'error': 'internal',
            'message': 'disk on fire',
          }),
          500,
        ),
      );
      final restingLeft = tester.getTopLeft(find.byKey(tile)).dx;

      await tester.drag(find.byKey(tile), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.delete.confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /notes/01H'));
      expect(find.text('swiped'), findsOneWidget);
      expect(find.byKey(const Key('notes.error')), findsOneWidget);
      expect(find.text('Note deleted'), findsNothing);
      expect(tester.getTopLeft(find.byKey(tile)).dx, restingLeft);
    });

    testWidgets('swiping toward the trailing edge does nothing', (
      tester,
    ) async {
      final calls = <String>[];
      await pumpRow(tester, calls: calls);
      final restingLeft = tester.getTopLeft(find.byKey(tile)).dx;

      await tester.drag(find.byKey(tile), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(find.text('Delete this note?'), findsNothing);
      expect(calls, isNot(contains('DELETE /notes/01H')));
      expect(tester.getTopLeft(find.byKey(tile)).dx, restingLeft);
    });

    testWidgets('the long-press menu still works alongside the swipe', (
      tester,
    ) async {
      final calls = <String>[];
      await pumpRow(tester, calls: calls);

      await tester.longPress(find.byKey(tile));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.tile.01H.delete')), findsOneWidget);
    });
  });

  group('create action placement', () {
    testWidgets('on a narrow screen, the FAB has a tooltip naming its action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async {
        return _page(<Object?>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(controller: ctrl, onCreateNote: () {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Create'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'New note'), findsNothing);
    });

    testWidgets(
      'on a wide screen, a labelled New note action replaces the FAB',
      (tester) async {
        tester.view.physicalSize = const Size(800, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final mock = MockClient((request) async {
          return _page(<Object?>[]);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NotesListController(api: api);
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: NotesListScreen(controller: ctrl, onCreateNote: () {}),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byKey(const Key('notes.create.toolbar')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('New note'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the wide New note action invokes onCreateNote when tapped', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async {
        return _page(<Object?>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      var created = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            onCreateNote: () => created = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.toolbar')));
      await tester.pump();

      expect(created, isTrue);
    });
  });

  group('narrow layout bottom navigation', () {
    Future<void> setNarrow(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('shows Search, Folders, and Account destinations', (
      tester,
    ) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
            onSearch: () {},
            onAccount: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.bottomNav.search')), findsOneWidget);
      expect(find.byKey(const Key('notes.bottomNav.folders')), findsOneWidget);
      expect(find.byKey(const Key('notes.bottomNav.account')), findsOneWidget);
    });

    testWidgets('hides the AppBar hamburger and the toolbar actions', (
      tester,
    ) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
            onCreateNote: () {},
            onUploadFile: () {},
            onSearch: () {},
            onAccount: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byKey(const Key('shell.refresh')), findsNothing);
      expect(find.byKey(const Key('shell.search')), findsNothing);
      expect(find.byKey(const Key('shell.account')), findsNothing);
      expect(find.byKey(const Key('notes.create.toolbar')), findsNothing);
      expect(
        find.byKey(const Key('notes.create.upload.toolbar')),
        findsNothing,
      );
    });

    testWidgets('tapping Search invokes onSearch', (tester) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      var searched = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
            onSearch: () => searched = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.bottomNav.search')));
      await tester.pump();

      expect(searched, isTrue);
    });

    testWidgets('tapping Account invokes onAccount', (tester) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      var accountTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
            onAccount: () => accountTapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.bottomNav.account')));
      await tester.pump();

      expect(accountTapped, isTrue);
    });

    testWidgets('tapping Folders opens the sidebar drawer', (tester) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SIDEBAR'), findsNothing);

      await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
      await tester.pumpAndSettle();

      expect(find.text('SIDEBAR'), findsOneWidget);
    });

    testWidgets('dragging from the leading edge opens the sidebar drawer', (
      tester,
    ) async {
      await setNarrow(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SIDEBAR'), findsNothing);
      expect(
        tester
            .widget<Scaffold>(find.byType(Scaffold))
            .drawerEnableOpenDragGesture,
        isTrue,
      );

      // Start inside the edge-drag zone and pull toward the center.
      await tester.dragFrom(const Offset(5, 400), const Offset(250, 0));
      await tester.pumpAndSettle();

      expect(find.text('SIDEBAR'), findsOneWidget);
      expect(find.byKey(const Key('notes.sidebar.drawer')), findsOneWidget);
    });

    testWidgets('is absent on a wide layout', (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
            onSearch: () {},
            onAccount: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.bottomNav.search')), findsNothing);
    });
  });

  group('wide toolbar', () {
    Future<void> setWide(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('renders every action in contract order with its callback', (
      tester,
    ) async {
      await setWide(tester);
      var refreshes = 0;
      final mock = MockClient((request) async {
        refreshes += 1;
        return _page(<Object?>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);
      final log = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            onCreateNote: () => log.add('create'),
            onUploadFile: () => log.add('upload'),
            onSearch: () => log.add('search'),
            onAccount: () => log.add('account'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);

      const keys = [
        'notes.create.toolbar',
        'notes.create.upload.toolbar',
        'shell.search',
        'shell.refresh',
        'shell.account',
      ];
      final xs = [
        for (final k in keys) tester.getTopLeft(find.byKey(Key(k))).dx,
      ];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '${keys[i]} order');
      }
      expect(find.byTooltip('Upload file'), findsOneWidget);
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.byTooltip('Account'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);

      await tester.tap(find.byKey(const Key('notes.create.upload.toolbar')));
      await tester.tap(find.byKey(const Key('shell.search')));
      await tester.tap(find.byKey(const Key('shell.account')));
      await tester.tap(find.byKey(const Key('shell.refresh')));
      await tester.pumpAndSettle();

      expect(log, ['upload', 'search', 'account']);
      expect(refreshes, 2);
    });

    testWidgets('the upload action is reachable on wide layouts', (
      tester,
    ) async {
      await setWide(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);
      var uploaded = false;

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            onUploadFile: () => uploaded = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('notes.create.upload.toolbar')),
      );
      expect((button.icon as Icon).icon, Icons.upload_file);
      await tester.tap(find.byKey(const Key('notes.create.upload.toolbar')));
      await tester.pump();
      expect(uploaded, isTrue);
    });

    testWidgets('optional actions are omitted when their callback is null', (
      tester,
    ) async {
      await setWide(tester);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell.refresh')), findsOneWidget);
      expect(find.byKey(const Key('notes.create.toolbar')), findsNothing);
      expect(
        find.byKey(const Key('notes.create.upload.toolbar')),
        findsNothing,
      );
      expect(find.byKey(const Key('shell.search')), findsNothing);
      expect(find.byKey(const Key('shell.account')), findsNothing);
    });
  });

  group('layout', () {
    testWidgets('derives wide chrome from its own constraints at >= 600', (
      tester,
    ) async {
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      Widget app(double width) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            height: 500,
            child: NotesListScreen(
              controller: ctrl,
              sidebar: const Text('SIDEBAR'),
              onSearch: () {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(app(599));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.bottomNav.search')), findsOneWidget);
      expect(find.byKey(const Key('notes.sidebar.wide')), findsNothing);

      await tester.pumpWidget(app(600));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.bottomNav.search')), findsNothing);
      expect(find.byKey(const Key('notes.sidebar.wide')), findsOneWidget);
    });

    testWidgets('layout: wide overrides a narrow width', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            layout: NotesListLayout.wide,
            onCreateNote: () {},
            onSearch: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.create.toolbar')), findsOneWidget);
      expect(find.byKey(const Key('shell.search')), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byKey(const Key('notes.bottomNav.search')), findsNothing);
    });

    testWidgets('layout: narrow overrides a wide width', (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            layout: NotesListLayout.narrow,
            sidebar: const Text('SIDEBAR'),
            onCreateNote: () {},
            onSearch: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes.create')), findsOneWidget);
      expect(find.byKey(const Key('notes.bottomNav.search')), findsOneWidget);
      expect(find.byKey(const Key('notes.create.toolbar')), findsNothing);
      expect(find.byKey(const Key('notes.sidebar.wide')), findsNothing);
      expect(find.text('SIDEBAR'), findsNothing);

      await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.sidebar.drawer')), findsOneWidget);
      expect(find.text('SIDEBAR'), findsOneWidget);
    });

    testWidgets('the inline sidebar sits in a resizable panel', (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(
            controller: ctrl,
            sidebar: const Text('SIDEBAR'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final box = find.byKey(const Key('notes.sidebar.wide'));
      expect(tester.getSize(box).width, PaneSizes.sidebarDefault);
      expect(find.byType(VerticalDivider), findsNothing);

      await _dragHandle(tester, 60);
      expect(tester.getSize(box).width, PaneSizes.sidebarDefault + 60);

      // Clamped at the shared maximum.
      await _dragHandle(tester, 1000);
      expect(tester.getSize(box).width, PaneSizes.sidebarMax);
    });
  });

  group('title', () {
    Future<NotesListController> pump(WidgetTester tester) async {
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      return ctrl;
    }

    String title(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('notes.title'))).data!;

    testWidgets('is "Notes" when unscoped', (tester) async {
      await pump(tester);
      expect(title(tester), 'Notes');
    });

    testWidgets('is the last path segment of the selected folder', (
      tester,
    ) async {
      final ctrl = await pump(tester);
      await ctrl.selectFolder('Projects/Alpha');
      await tester.pumpAndSettle();
      expect(title(tester), 'Alpha');

      await ctrl.selectFolder('Inbox');
      await tester.pumpAndSettle();
      expect(title(tester), 'Inbox');
    });

    testWidgets('is "Root" for the vault root', (tester) async {
      final ctrl = await pump(tester);
      await ctrl.selectFolder('');
      await tester.pumpAndSettle();
      expect(title(tester), 'Root');
    });
  });

  group('folder filter chip', () {
    testWidgets('shows the scope and clears it via the delete icon', (
      tester,
    ) async {
      final requestedPaths = <String?>[];
      final mock = MockClient((request) async {
        requestedPaths.add(request.url.queryParameters['path']);
        return _page(<Object?>[_metaJson(id: '01H', title: 'hello')]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.filter.folder')), findsNothing);

      await ctrl.selectFolder('Projects/Alpha');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.filter.folder')), findsOneWidget);
      expect(find.text('Folder: Alpha'), findsOneWidget);

      await tester.tap(find.byKey(const Key('notes.filter.folder.clear')));
      await tester.pumpAndSettle();

      expect(ctrl.value.selectedPath, isNull);
      expect(find.byKey(const Key('notes.filter.folder')), findsNothing);
      expect(requestedPaths.last, isNull);
    });

    testWidgets('folder and tag chips render together', (tester) async {
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      await ctrl.selectFolder('');
      await ctrl.selectTag('urgent');
      await tester.pumpAndSettle();

      expect(find.text('Folder: Root'), findsOneWidget);
      expect(find.text('Tag: urgent'), findsOneWidget);
    });
  });

  group('empty state', () {
    Future<NotesListController> pump(
      WidgetTester tester, {
      VoidCallback? onCreateNote,
    }) async {
      final mock = MockClient((request) async => _page(<Object?>[]));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NotesListScreen(controller: ctrl, onCreateNote: onCreateNote),
        ),
      );
      await tester.pumpAndSettle();
      return ctrl;
    }

    testWidgets('unscoped: "No notes yet" with a New note action', (
      tester,
    ) async {
      var created = false;
      await pump(tester, onCreateNote: () => created = true);

      expect(find.byKey(const Key('notes.empty')), findsOneWidget);
      expect(find.text('No notes yet'), findsOneWidget);
      expect(find.byKey(const Key('notes.list')), findsNothing);

      await tester.tap(find.byKey(const Key('notes.empty.create')));
      await tester.pump();
      expect(created, isTrue);
    });

    testWidgets('unscoped without onCreateNote: no action button', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('notes.empty')), findsOneWidget);
      expect(find.byKey(const Key('notes.empty.create')), findsNothing);
    });

    testWidgets('folder scope: "Nothing in <folder>" with New note', (
      tester,
    ) async {
      final ctrl = await pump(tester, onCreateNote: () {});
      await ctrl.selectFolder('Projects/Alpha');
      await tester.pumpAndSettle();

      expect(find.text('Nothing in Alpha'), findsOneWidget);
      expect(find.byKey(const Key('notes.empty.create')), findsOneWidget);
      expect(find.byKey(const Key('notes.empty.clearFilter')), findsNothing);
    });

    testWidgets('tag scope: "No notes tagged #tag" with Clear filter', (
      tester,
    ) async {
      final ctrl = await pump(tester, onCreateNote: () {});
      await ctrl.selectTag('urgent');
      await tester.pumpAndSettle();

      expect(find.text('No notes tagged #urgent'), findsOneWidget);
      expect(find.byKey(const Key('notes.empty.create')), findsNothing);

      await tester.tap(find.byKey(const Key('notes.empty.clearFilter')));
      await tester.pumpAndSettle();
      expect(ctrl.value.selectedTag, isNull);
      expect(find.text('No notes yet'), findsOneWidget);
    });

    testWidgets('is not shown while loading or when a fetch failed', (
      tester,
    ) async {
      var calls = 0;
      final gate = Completer<void>();
      final mock = MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          await gate.future;
          return http.Response('', 503);
        }
        return _page(<Object?>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      // First frame: the initial fetch hasn't been issued yet.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('notes.empty')), findsNothing);
      // Second frame: fetch in flight.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('notes.empty')), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.error')), findsOneWidget);
      expect(find.byKey(const Key('notes.empty')), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.error')), findsNothing);
      expect(find.byKey(const Key('notes.empty')), findsOneWidget);
    });

    testWidgets('pull-to-refresh still works over the empty state on narrow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _page(<Object?>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: NotesListScreen(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.fling(
        find.byKey(const Key('notes.empty')),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(calls, 2);
    });
  });

  testWidgets('the FAB presents a menu with New note and New folder instead of '
      'creating instantly', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);
    var noteCreated = false;

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          onCreateNote: () => noteCreated = true,
          onCreateFolder: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();

    expect(noteCreated, isFalse);
    expect(find.byKey(const Key('notes.create.note')), findsOneWidget);
    expect(find.byKey(const Key('notes.create.folder')), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
  });

  testWidgets('choosing "New note" from the FAB menu invokes onCreateNote', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);
    var noteCreated = false;

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          onCreateNote: () => noteCreated = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notes.create.note')));
    await tester.pumpAndSettle();

    expect(noteCreated, isTrue);
  });

  testWidgets('no "New folder" menu item when onCreateFolder is omitted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(controller: ctrl, onCreateNote: () {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();

    expect(find.text('New folder'), findsNothing);
  });

  testWidgets('no "Upload file" menu item when onUploadFile is omitted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(controller: ctrl, onCreateNote: () {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();

    expect(find.text('Upload file'), findsNothing);
  });

  testWidgets('choosing "Upload file" from the FAB menu invokes onUploadFile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mock = MockClient((request) async {
      return _page(<Object?>[]);
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesListController(api: api);
    addTearDown(ctrl.dispose);
    var uploadRequested = false;

    await tester.pumpWidget(
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          onCreateNote: () {},
          onUploadFile: () => uploadRequested = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();
    expect(find.text('Upload file'), findsOneWidget);

    await tester.tap(find.byKey(const Key('notes.create.upload')));
    await tester.pumpAndSettle();

    expect(uploadRequested, isTrue);
  });
}
