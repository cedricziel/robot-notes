import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
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
    tester.view.physicalSize = const Size(1200, 800);
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

  testWidgets('a refresh action in the AppBar re-fetches the first page', (
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
      MaterialApp(
        home: NotesListScreen(
          controller: ctrl,
          appBarActions: [
            IconButton(
              key: const Key('shell.refresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: ctrl.refresh,
            ),
          ],
        ),
      ),
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

  group('formatNoteTimestamp', () {
    test('renders YYYY-MM-DD HH:MM with zero padding and no UTC marker', () {
      expect(
        formatNoteTimestamp(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02 03:04',
      );
    });

    test('renders a UTC instant as the local wall-clock time', () {
      final utc = DateTime.utc(2026, 9, 12, 10, 28);
      final l = utc.toLocal();
      final wallClock = DateTime(l.year, l.month, l.day, l.hour, l.minute);

      expect(formatNoteTimestamp(utc), formatNoteTimestamp(wallClock));
    });
  });

  group('formatRelativeNoteTime', () {
    final now = DateTime.utc(2026, 9, 12, 12, 0, 0);

    test('just now for less than a minute ago', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        'just now',
      );
    });

    test('singular minute', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        '1 minute ago',
      );
    });

    test('plural minutes', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        '5 minutes ago',
      );
    });

    test('singular hour', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        '1 hour ago',
      );
    });

    test('plural hours', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(hours: 5)),
          now: now,
        ),
        '5 hours ago',
      );
    });

    test('singular day', () {
      expect(
        formatRelativeNoteTime(now.subtract(const Duration(days: 1)), now: now),
        '1 day ago',
      );
    });

    test('plural days', () {
      expect(
        formatRelativeNoteTime(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
    });

    test('falls back to the absolute timestamp beyond a week', () {
      final then = now.subtract(const Duration(days: 8));
      expect(formatRelativeNoteTime(then, now: now), formatNoteTimestamp(then));
    });

    test('falls back to the absolute timestamp for a future update time', () {
      // Clock skew between server and client can put updatedAt slightly (or
      // not so slightly) ahead of "now" — the negative diff must not read
      // as "just now".
      final future = now.add(const Duration(hours: 3));
      expect(
        formatRelativeNoteTime(future, now: now),
        formatNoteTimestamp(future),
      );
    });
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

    testWidgets('shows the folder path trailing the title', (tester) async {
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

    testWidgets('shows a chip per tag', (tester) async {
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

      expect(find.widgetWithText(Chip, 'travel'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'urgent'), findsOneWidget);
    });

    testWidgets('shows no tag chips when the note has no tags', (tester) async {
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
        tester.view.physicalSize = const Size(1200, 800);
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
        tester.view.physicalSize = const Size(1200, 800);
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
        expect(find.text('New note'), findsOneWidget);

        await tester.tap(find.text('New note'));
        await tester.pump();
      },
    );

    testWidgets('the wide New note action invokes onCreateNote when tapped', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
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

      await tester.tap(find.text('New note'));
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

    testWidgets('hides the AppBar hamburger and old icon actions', (
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
            appBarActions: [
              IconButton(
                key: const Key('shell.refresh'),
                icon: const Icon(Icons.refresh),
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byKey(const Key('shell.refresh')), findsNothing);
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

    testWidgets('is absent on a wide layout', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
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

  testWidgets('the FAB presents a menu with New note and New folder instead of '
      'creating instantly', (tester) async {
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
    expect(find.text('New note'), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
  });

  testWidgets('choosing "New note" from the FAB menu invokes onCreateNote', (
    tester,
  ) async {
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
}
