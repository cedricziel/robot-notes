import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:app/src/api/api_client.dart';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/desktop/app_menu_actions.dart';
import 'package:app/src/desktop/app_menu_bar.dart';
import 'package:app/src/files/picked_file.dart';
import 'package:app/src/files/file_screen.dart';
import 'package:app/src/notes/folder_overview.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/layout/breakpoints.dart';
import 'package:app/src/lock/app_lock_controller.dart';
import 'package:app/src/lock/app_lock_gate.dart';
import 'package:app/src/lock/app_lock_prefs.dart';
import 'package:app/src/lock/biometric_authenticator.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/block_note_editor.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:app/src/search/search_screen.dart';
import 'package:app/src/vaults/vault_switcher.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoSheetRoute;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'lock/fakes.dart';

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

http.Response _emptyList() => http.Response(
  jsonEncode(<String, Object?>{
    'items': <Object?>[],
    'limit': 50,
    'next_cursor': null,
  }),
  200,
);

/// Fake backend shared by every scenario below: `GET /notes/01H` returns a
/// fixed note, `/notes/01H/lock` grants the lock the edit-mode scenario
/// needs, and a bare `GET /notes` returns an empty list page.
Future<http.Response> _fakeBackend(http.Request request) async {
  final path = request.url.path;
  final method = request.method;
  if (method == 'GET' && path == '/notes/01H') {
    return http.Response(jsonEncode(_noteJson()), 200);
  }
  if (path == '/notes/01H/lock' && (method == 'POST' || method == 'PUT')) {
    return http.Response(
      jsonEncode(<String, Object?>{
        'holder': 'cedric',
        'expires_at': '2099-01-01T00:00:00.000Z',
      }),
      200,
    );
  }
  if (method == 'GET' && path == '/notes') {
    return _emptyList();
  }
  if (method == 'GET' && path == '/notes/files') {
    return http.Response(jsonEncode({'items': <Object?>[]}), 200);
  }
  if (method == 'GET' && path == '/notes/tree') {
    return http.Response(
      jsonEncode(<String, Object?>{'folders': <Object?>[]}),
      200,
    );
  }
  return http.Response('not found', 404);
}

MockClient _mockClient() => MockClient(_fakeBackend);

const _dbNow = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _databaseDefinitionJson({
  String id = '01D',
}) => <String, Object?>{
  'id': id,
  'title': 'Projects',
  'path': '',
  'version': 1,
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'properties': <String, Object?>{
    'status': <String, Object?>{
      'type': 'select',
      'options': ['Idea', 'Active', 'Done'],
    },
  },
  'views': <Object?>[
    <String, Object?>{
      'name': 'All',
      'type': 'table',
      'properties': ['status'],
    },
    <String, Object?>{'name': 'Kanban', 'type': 'board', 'group_by': 'status'},
  ],
  'created_at': _dbNow,
  'updated_at': _dbNow,
};

/// A backend that additionally serves `GET /databases/01D` and
/// `POST /databases/01D/query` with an empty page, for the `/databases/:id`
/// route tests below.
Future<http.Response> _databaseBackend(http.Request request) async {
  final path = request.url.path;
  if (request.method == 'GET' && path == '/databases/01D') {
    return http.Response(jsonEncode(_databaseDefinitionJson()), 200);
  }
  if (request.method == 'POST' && path == '/databases/01D/query') {
    return http.Response(
      jsonEncode(<String, Object?>{'items': <Object?>[], 'next_cursor': null}),
      200,
    );
  }
  return _fakeBackend(request);
}

MockClient _databaseMockClient() => MockClient(_databaseBackend);

/// Router-level test harness: a real [GoRouter] from [buildAppRouter], but
/// wrapped in a hand-rolled [AppSession] instead of the production
/// [SessionHost] so the test owns the [RobotNotesWsClient] and never starts
/// a real socket connection.
Widget _harness({
  required RobotNotesClient api,
  required String initialLocation,
  VoidCallback? onReset,
  PickFile? pickFile,
  GoRouter? router,
  ValueNotifier<ConnectionStatus>? connection,
  AppMenuActions? menuActions,
  // Wraps the routed content inside [AppSession], e.g. to pin an ambient
  // MediaQuery (a macOS unified-title-bar inset) around the shell.
  Widget Function(Widget)? wrapContent,
}) {
  final ws = RobotNotesWsClient(config: _config);
  final list = NotesListController(api: api);
  final tree = FolderTreeController(api: api);
  final databases = DatabasesController(api: api);
  final goRouter =
      router ??
      buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: initialLocation,
        pickFile: pickFile ?? () async => null,
      );
  final app = MaterialApp.router(
    routerConfig: goRouter,
    builder: (context, child) => AppSession(
      api: api,
      ws: ws,
      list: list,
      tree: tree,
      databases: databases,
      actor: _config.actor,
      baseUrl: _config.baseUrl,
      connection: connection ?? ValueNotifier(ConnectionStatus.connected),
      onReset: onReset ?? () {},
      child: wrapContent == null ? child! : wrapContent(child!),
    ),
  );
  if (menuActions == null) return app;
  return AppMenuActionsScope(actions: menuActions, child: app);
}

/// Sets the test window to [size] logical pixels (1:1 device pixels) and
/// restores the default once the test ends.
void _setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Presses [key] while [modifier] is held, the way a user types a chord.
Future<void> _pressChord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? secondModifier,
}) async {
  await tester.sendKeyDownEvent(modifier);
  if (secondModifier != null) await tester.sendKeyDownEvent(secondModifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (secondModifier != null) await tester.sendKeyUpEvent(secondModifier);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

Future<void> _closeNote(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('note.close')));
  await tester.pumpAndSettle();
}

/// Backend that additionally lists one note (`01H`, "hello") so the notes
/// list has a row to tap.
Future<http.Response> _backendWithOneNote(http.Request request) async {
  if (request.method == 'GET' && request.url.path == '/notes') {
    return http.Response(
      jsonEncode(<String, Object?>{
        'items': <Object?>[_noteJson()],
        'limit': 50,
        'next_cursor': null,
      }),
      200,
    );
  }
  return _fakeBackend(request);
}

/// The "hello" row inside the notes list (the open note's title also
/// reads "hello", so the list must be named explicitly).
Finder _listRow() => find.descendant(
  of: find.byType(NotesListScreen),
  matching: find.byKey(const Key('notes.tile.01H')),
);

void main() {
  testWidgets('file deep link expands ancestors and highlights its row', (
    tester,
  ) async {
    _setWindow(tester, const Size(1000, 900));
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/tree') {
          return http.Response(
            jsonEncode({
              'folders': [
                {'path': 'Projects/Alpha', 'note_count': 0, 'file_count': 1},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/notes/files') {
          return http.Response(
            jsonEncode({
              'items': request.url.queryParameters['path'] == 'Projects/Alpha'
                  ? [
                      {
                        'path': 'Projects/Alpha',
                        'filename': 'data.txt',
                        'size': 3,
                        'content_type': 'text/plain',
                        'updated_at': _now,
                      },
                    ]
                  : <Object?>[],
            }),
            200,
          );
        }
        return _fakeBackend(request);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      _harness(
        api: api,
        initialLocation: '/file?path=Projects%2FAlpha%2Fdata.txt',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse Projects'), findsOneWidget);
    expect(find.byTooltip('Collapse Alpha'), findsOneWidget);
    final row = find.byKey(const Key('sidebar.file.Projects/Alpha/data.txt'));
    expect(row, findsOneWidget);
    expect(tester.widget<ListTile>(row).selected, isTrue);
  });

  testWidgets('session shell waits for redirect when configuration is absent', (
    tester,
  ) async {
    final holder = ConfigHolder.seeded(null);
    addTearDown(holder.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppRouterShell(
          configHolder: holder,
          child: const Text('Authenticated content'),
        ),
      ),
    );
    expect(find.text('Authenticated content'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('workspace vault controls can open a dialog inside the router', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/vaults') {
          return http.Response(
            jsonEncode({
              'can_manage': true,
              'vaults': [
                {'id': 'default', 'name': 'Default'},
              ],
            }),
            200,
          );
        }
        return _fakeBackend(request);
      }),
    );
    addTearDown(api.close);
    final holder = ConfigHolder.seeded(_config);
    addTearDown(holder.dispose);
    final router = buildAppRouter(
      configHolder: holder,
      sessionBuilder: (context, child) => Column(
        children: [
          VaultSwitcher(
            api: api,
            selectedId: 'default',
            onSelect: (_) {},
            canManage: true,
          ),
          Expanded(child: child),
        ],
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _harness(api: api, initialLocation: '/', router: router),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create vault'));
    await tester.pumpAndSettle();
    expect(find.text('Vault name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(NotesListScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tag in a compact search result opens the filtered Notes tab', (
    tester,
  ) async {
    _setWindow(tester, const Size(390, 844));
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(
            jsonEncode({
              ..._noteJson(),
              'tags': ['release'],
            }),
            200,
          );
        }
        return _backendWithOneNote(request);
      }),
    );
    addTearDown(api.close);
    final router = buildAppRouter(
      configHolder: ConfigHolder.seeded(_config),
      initialLocation: '/',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _harness(api: api, initialLocation: '/', router: router),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shell.tab.search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search.recent.01H')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note.tags.chip.release')));
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(
      tester
          .widget<NavigationBar>(find.byKey(const Key('shell.destinations')))
          .selectedIndex,
      0,
    );
    expect(find.byKey(const Key('notes.filter.tag')), findsOneWidget);
    expect(find.byKey(const Key('search.input')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mounted compact Search refreshes recent notes with the list', (
    tester,
  ) async {
    _setWindow(tester, const Size(390, 844));
    var title = 'Before refresh';
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes') {
          return http.Response(
            jsonEncode({
              'items': [_noteJson(title: title)],
              'limit': 50,
            }),
            200,
          );
        }
        return _fakeBackend(request);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shell.tab.search')));
    await tester.pumpAndSettle();
    expect(find.text('Before refresh'), findsOneWidget);
    final session = AppSession.of(tester.element(find.byType(SearchScreen)));
    title = 'After refresh';
    await session.list.refresh();
    await tester.pumpAndSettle();
    expect(find.text('After refresh'), findsOneWidget);
    expect(find.text('Before refresh'), findsNothing);
  });

  group('responsive device regression matrix', () {
    const cases = [
      (
        name: 'iPhone portrait',
        platform: TargetPlatform.iOS,
        size: Size(390, 844),
      ),
      (
        name: 'iPhone landscape',
        platform: TargetPlatform.iOS,
        size: Size(844, 390),
      ),
      (
        name: 'tablet portrait',
        platform: TargetPlatform.iOS,
        size: Size(768, 1024),
      ),
      (
        name: 'tablet landscape',
        platform: TargetPlatform.iOS,
        size: Size(1024, 768),
      ),
      (
        name: 'Linux desktop',
        platform: TargetPlatform.linux,
        size: Size(1280, 800),
      ),
      (
        name: 'Mac desktop',
        platform: TargetPlatform.macOS,
        size: Size(1440, 900),
      ),
      (
        name: 'compact browser window',
        platform: TargetPlatform.linux,
        size: Size(360, 640),
      ),
    ];

    for (final scenario in cases) {
      testWidgets('${scenario.name} opens and closes a note without overflow', (
        tester,
      ) async {
        _setWindow(tester, scenario.size);
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient(_backendWithOneNote),
        );
        addTearDown(api.close);
        final router = buildAppRouter(
          configHolder: ConfigHolder.seeded(_config),
          initialLocation: '/',
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/', router: router),
        );
        await tester.pumpAndSettle();

        final sizeClass = Breakpoints.classify(scenario.size.width);
        final compact = sizeClass == WindowSizeClass.compact;
        final desktop = sizeClass >= WindowSizeClass.expanded;
        expect(
          find.byKey(const Key('shell.destinations')),
          compact ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('notes.sidebar.wide')),
          !compact && !desktop ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('shell.sidebar')),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
        expect(_listRow(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(_listRow());
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/notes/01H');
        expect(find.byType(BlockNoteEditor), findsOneWidget);
        expect(find.text('world', findRichText: true), findsOneWidget);
        expect(find.byType(NotesListScreen), findsNothing);
        if (desktop) {
          expect(
            tester.getTopLeft(find.byType(BlockNoteEditor)).dx,
            greaterThanOrEqualTo(PaneSizes.sidebarMin),
          );
        }
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('note.close')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/');
        expect(_listRow(), findsOneWidget);
        expect(find.byType(BlockNoteEditor), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({scenario.platform}));
    }

    testWidgets(
      'live rotation and resizing preserve the note and search destination',
      (tester) async {
        _setWindow(tester, const Size(390, 844));
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient(_backendWithOneNote),
        );
        addTearDown(api.close);
        final router = buildAppRouter(
          configHolder: ConfigHolder.seeded(_config),
          initialLocation: '/notes/01H',
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/notes/01H', router: router),
        );
        await tester.pumpAndSettle();

        // Keep the same router/session mounted while crossing every layout class.
        for (final size in [
          const Size(844, 390),
          const Size(768, 1024),
          const Size(1440, 900),
          const Size(390, 844),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(router.routeInformationProvider.value.uri.path, '/notes/01H');
          expect(find.byType(BlockNoteEditor), findsOneWidget);
          expect(find.text('world', findRichText: true), findsOneWidget);
          expect(
            find.byKey(const Key('shell.sidebar')),
            size.width >= Breakpoints.expanded ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull, reason: 'Note at $size');
        }

        await tester.tap(find.byKey(const Key('note.close')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell.tab.search')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('search.input')),
          'release',
        );
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shell.destinations')), findsNothing);
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<NavigationBar>(
                find.byKey(const Key('shell.destinations')),
              )
              .selectedIndex,
          2,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('search.input')))
              .controller!
              .text,
          'release',
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  });

  testWidgets(
    'compact destinations retain search and provide a database library',
    (tester) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search.input')), findsNothing);
      await tester.tap(find.byKey(const Key('shell.tab.search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search.input')), 'release');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell.tab.databases')));
      await tester.pumpAndSettle();
      expect(find.text('Your structured notes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shell.tab.search')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('search.input')))
            .controller!
            .text,
        'release',
      );
      await tester.tap(find.byKey(const Key('shell.tab.notes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.title')), findsOneWidget);
    },
  );

  testWidgets('iPhone shortcut search uses a dismissible bottom sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _setWindow(tester, const Size(400, 800));
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);
    await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
    await tester.pumpAndSettle();
    await _pressChord(
      tester,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.keyK,
    );
    expect(
      ModalRoute.of(tester.element(find.byType(SearchScreen))),
      isA<CupertinoSheetRoute<void>>(),
    );
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.byKey(const Key('search.close')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed create-note request shows a real error, not "null"', (
    tester,
  ) async {
    // Regression test: the server's error body for a 500 carries no
    // "message" key, so ApiException.message is null. The FAB handler
    // used to interpolate that raw into the SnackBar text, literally
    // showing "Could not create note: null" with no diagnostic value.
    //
    // Forced narrow: the FAB only renders below the wide-layout
    // breakpoint, and this test is about the error message, not layout.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/notes') {
          return http.Response('', 500);
        }
        return _fakeBackend(request);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notes.create.toolbar')));
    await tester.pumpAndSettle();

    expect(find.textContaining('null'), findsNothing);
    expect(find.text('Could not create note.'), findsOneWidget);
  });

  group('upload file from the FAB', () {
    testWidgets('choosing "Upload file" and picking a file uploads it into the '
        'currently selected folder', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic>? capturedFields;
      // MultipartRequest's `fields`/`files` are only inspectable on the
      // raw BaseRequest handed to a *streaming* mock handler — the plain
      // `MockClient` reconstructs a bodyless-of-that-info `Request`
      // before invoking its handler, which loses them.
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient.streaming((request, bodyStream) async {
          if (request.method == 'GET' && request.url.path == '/notes/tree') {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode(<String, Object?>{
                    'folders': [
                      {'path': 'Projects/Alpha', 'note_count': 1},
                    ],
                  }),
                ),
              ),
              200,
              request: request,
            );
          }
          if (request.method == 'POST' && request.url.path == '/notes/files') {
            final multipart = request as http.MultipartRequest;
            capturedFields = <String, dynamic>{
              'path': multipart.fields['path'],
              'filename': multipart.files.single.filename,
            };
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode(<String, Object?>{
                    'path': multipart.fields['path'],
                    'filename': multipart.files.single.filename,
                    'size': 3,
                    'content_type': 'application/octet-stream',
                  }),
                ),
              ),
              201,
              request: request,
            );
          }
          if (request.method == 'GET' && request.url.path == '/notes/files') {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'items':
                        capturedFields != null &&
                            request.url.queryParameters['path'] ==
                                capturedFields!['path']
                        ? [
                            {
                              'path': capturedFields!['path'],
                              'filename': capturedFields!['filename'],
                              'size': 3,
                              'content_type': 'image/png',
                              'updated_at': _now,
                            },
                          ]
                        : <Object?>[],
                  }),
                ),
              ),
              200,
              request: request,
            );
          }
          final res = await _fakeBackend(
            http.Request(request.method, request.url)
              ..headers.addAll(request.headers),
          );
          return http.StreamedResponse(
            Stream.value(res.bodyBytes),
            res.statusCode,
            request: request,
            headers: res.headers,
          );
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          pickFile: () async =>
              PickedFile(name: 'diagram.png', bytes: Uint8List(3)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.sidebar.open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Upload file'));
      await tester.pumpAndSettle();

      expect(capturedFields?['path'], 'Projects/Alpha');
      expect(capturedFields?['filename'], 'diagram.png');
      expect(find.text('Uploaded diagram.png'), findsOneWidget);
      expect(
        find.byKey(const Key('sidebar.file.Projects/Alpha/diagram.png')),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the file picker sends no request', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var uploadRequested = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes/files') {
            uploadRequested = true;
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', pickFile: () async => null),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.create.upload')));
      await tester.pumpAndSettle();

      expect(uploadRequested, isFalse);
    });

    testWidgets('a failed upload shows the server error via a SnackBar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes/files') {
            return http.Response(
              jsonEncode(<String, Object?>{'error': 'payload_too_large'}),
              413,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          pickFile: () async =>
              PickedFile(name: 'huge.bin', bytes: Uint8List(3)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.create.upload')));
      await tester.pumpAndSettle();

      expect(find.text('Could not upload file.'), findsOneWidget);
    });
  });

  group('narrow layout bottom nav wiring', () {
    Future<void> setNarrow(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('Search opens the search screen', (tester) async {
      await setNarrow(tester);
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
    });

    testWidgets('Folders opens the drawer with the folder tree', (
      tester,
    ) async {
      await setNarrow(tester);
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sidebar.allNotes')), findsNothing);

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.sidebar.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sidebar.allNotes')), findsOneWidget);
    });

    testWidgets(
      'Account opens the account sheet; Disconnect confirms, then resets',
      (tester) async {
        await setNarrow(tester);
        final api = RobotNotesClient(
          config: _config,
          httpClient: _mockClient(),
        );
        addTearDown(api.close);
        final connection = ValueNotifier(ConnectionStatus.reconnecting);
        addTearDown(connection.dispose);
        var wasReset = false;

        await tester.pumpWidget(
          _harness(
            api: api,
            initialLocation: '/',
            onReset: () => wasReset = true,
            connection: connection,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('shell.tab.settings')));
        await tester.pumpAndSettle();

        // Settings is a persistent destination on compact screens.
        expect(find.byKey(const Key('account.sheet')), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const Key('account.server'))).data,
          'https://notes.example',
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('account.actor'))).data,
          'cedric',
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('account.connection'))).data,
          'Reconnecting…',
        );

        // The connection row is live.
        connection.value = ConnectionStatus.connected;
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('account.connection'))).data,
          'Connected',
        );
        expect(find.text('Disconnect from server?'), findsNothing);

        await tester.tap(find.byKey(const Key('account.disconnect')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account.sheet')), findsOneWidget);
        expect(find.text('Disconnect from server?'), findsOneWidget);
        expect(wasReset, isFalse);

        await tester.tap(find.byKey(const Key('account.disconnect.confirm')));
        await tester.pumpAndSettle();

        expect(wasReset, isTrue);
      },
    );

    testWidgets('Account offers the app lock and turns it on after a prompt', (
      tester,
    ) async {
      await setNarrow(tester);
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      final auth = FakeBiometricAuthenticator();
      final lock = AppLockController(
        authenticator: auth,
        prefs: InMemoryAppLockPrefs(),
      );
      addTearDown(lock.dispose);
      await lock.load();

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          wrapContent: (c) => AppLockScope(controller: lock, child: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell.tab.settings')));
      await tester.pumpAndSettle();

      final tile = find.byKey(const Key('account.appLock'));
      expect(tile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(auth.authenticateCalls, 1);
      expect(lock.enabled, isTrue);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    });

    testWidgets('Account leaves the app lock out when it is unsupported', (
      tester,
    ) async {
      await setNarrow(tester);
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      final lock = AppLockController(
        authenticator: FakeBiometricAuthenticator(
          capability: LockCapability.unsupported,
        ),
        prefs: InMemoryAppLockPrefs(),
      );
      addTearDown(lock.dispose);
      await lock.load();

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          wrapContent: (c) => AppLockScope(controller: lock, child: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell.tab.settings')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account.sheet')), findsOneWidget);
      expect(find.byKey(const Key('account.appLock')), findsNothing);
    });

    testWidgets('cancelling the disconnect confirmation keeps the session', (
      tester,
    ) async {
      await setNarrow(tester);
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      var wasReset = false;

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          onReset: () => wasReset = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell.tab.settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account.disconnect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(wasReset, isFalse);
      expect(find.text('Disconnect from server?'), findsNothing);
    });
  });

  testWidgets('on a wide window the account surface is a dialog', (
    tester,
  ) async {
    _setWindow(tester, const Size(800, 600));
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);
    var wasReset = false;

    await tester.pumpWidget(
      _harness(api: api, initialLocation: '/', onReset: () => wasReset = true),
    );
    await tester.pumpAndSettle();

    // The old direct "Disconnect" toolbar action is gone.
    expect(find.byKey(const Key('shell.reset')), findsNothing);

    await tester.tap(find.byKey(const Key('shell.account')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account.sheet')), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byKey(const Key('account.disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account.disconnect.confirm')));
    await tester.pumpAndSettle();

    expect(wasReset, isTrue);
  });

  testWidgets('choosing "New note" targets the currently selected folder', (
    tester,
  ) async {
    Map<String, dynamic>? createBody;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/tree') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'folders': [
                {'path': 'Projects/Alpha', 'note_count': 1},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == '/notes') {
          createBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_noteJson()), 201);
        }
        return _fakeBackend(request);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();

    expect(createBody?['path'], 'Projects/Alpha');

    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'choosing "New note" with no folder selected uses the vault root',
    (tester) async {
      Map<String, dynamic>? createBody;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes') {
            createBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode(_noteJson()), 201);
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.toolbar')));
      await tester.pumpAndSettle();

      expect(createBody?['path'], '');

      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'choosing "New folder" from the FAB creates it and refreshes the tree',
    (tester) async {
      // The FAB's "New folder" menu item only exists on the narrow layout
      // — on wide, folder creation is reached via the inline sidebar's own
      // action instead (covered by the sidebar test below).
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var folderCreated = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes/tree') {
            folderCreated = true;
            return http.Response(
              jsonEncode(<String, Object?>{'path': 'Ideas', 'note_count': 0}),
              201,
            );
          }
          if (request.method == 'GET' && request.url.path == '/notes/tree') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'folders': folderCreated
                    ? [
                        {'path': 'Ideas', 'note_count': 0},
                      ]
                    : <Object?>[],
              }),
              200,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.create.folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder.create.input')),
        'Ideas',
      );
      await tester.tap(find.byKey(const Key('folder.create.confirm')));
      await tester.pumpAndSettle();

      // The sidebar lives in a drawer on this narrow layout; open it to
      // see the refreshed tree.
      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.sidebar.open')));
      await tester.pumpAndSettle();

      expect(find.text('Ideas'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed "New folder" from the FAB shows the server error and leaves '
    'the prompt open',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes/tree') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'bad_request',
                'message': 'path is required and must be a non-empty string',
              }),
              400,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.create.folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder.create.input')),
        'Ideas',
      );
      await tester.tap(find.byKey(const Key('folder.create.confirm')));
      await tester.pumpAndSettle();

      expect(
        find.text('path is required and must be a non-empty string'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('folder.create.confirm')), findsOneWidget);
    },
  );

  testWidgets(
    'creating a folder from the sidebar refreshes the tree so it appears',
    (tester) async {
      var folderCreated = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes/tree') {
            folderCreated = true;
            return http.Response(
              jsonEncode(<String, Object?>{'path': 'Ideas', 'note_count': 0}),
              201,
            );
          }
          if (request.method == 'GET' && request.url.path == '/notes/tree') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'folders': folderCreated
                    ? [
                        {'path': 'Ideas', 'note_count': 0},
                      ]
                    : <Object?>[],
              }),
              200,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      expect(find.text('Ideas'), findsNothing);

      await tester.tap(find.byKey(const Key('sidebar.newFolder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder.create.input')),
        'Ideas',
      );
      await tester.tap(find.byKey(const Key('folder.create.confirm')));
      await tester.pumpAndSettle();

      expect(find.text('Ideas'), findsOneWidget);
    },
  );

  testWidgets('/notes/01H deep link renders that note', (tester) async {
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);

    await tester.pumpWidget(_harness(api: api, initialLocation: '/notes/01H'));
    await tester.pumpAndSettle();

    expect(find.byType(BlockNoteEditor), findsOneWidget);
    expect(find.text('world', findRichText: true), findsOneWidget);
  });

  testWidgets('/notes/01H?edit=1 opens the editor', (tester) async {
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);

    await tester.pumpWidget(
      _harness(api: api, initialLocation: '/notes/01H?edit=1'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note.editor.title')), findsOneWidget);
    expect(find.byKey(const Key('note.save')), findsOneWidget);

    await _closeNote(tester);
  });

  group('/databases/:id route', () {
    testWidgets(
      '/databases/01D?view=Kanban deep link renders the real screen with '
      'the definition title and the requested view selected',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: _databaseMockClient(),
        );
        addTearDown(api.close);

        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/databases/01D?view=Kanban'),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database.title')), findsOneWidget);
        expect(find.text('Projects'), findsOneWidget);
        final chip = tester.widget<ChoiceChip>(
          find.byKey(const Key('database.view.Kanban')),
        );
        expect(chip.selected, isTrue);
      },
    );

    testWidgets(
      '/databases/01D with no view query param resolves to the first view',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: _databaseMockClient(),
        );
        addTearDown(api.close);

        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/databases/01D'),
        );
        await tester.pumpAndSettle();

        final chip = tester.widget<ChoiceChip>(
          find.byKey(const Key('database.view.All')),
        );
        expect(chip.selected, isTrue);
      },
    );

    testWidgets(
      'an unknown ?view= falls back to the first view and rewrites the URL',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: _databaseMockClient(),
        );
        addTearDown(api.close);
        final router = buildAppRouter(
          configHolder: ConfigHolder.seeded(_config),
          initialLocation: '/databases/01D?view=Bogus',
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          _harness(
            api: api,
            initialLocation: '/databases/01D?view=Bogus',
            router: router,
          ),
        );
        await tester.pumpAndSettle();

        final chip = tester.widget<ChoiceChip>(
          find.byKey(const Key('database.view.All')),
        );
        expect(chip.selected, isTrue);
        expect(
          router.routeInformationProvider.value.uri.toString(),
          '/databases/01D?view=All',
        );
      },
    );

    testWidgets('the setup redirect applies to a database deep link too', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: _databaseMockClient(),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(null),
        initialLocation: '/databases/01D',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/databases/01D', router: router),
      );
      await tester.pumpAndSettle();

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/setup?from=%2Fdatabases%2F01D',
      );
    });

    testWidgets(
      'closing a deep-linked database (no history) lands on the notes list',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: _databaseMockClient(),
        );
        addTearDown(api.close);

        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/databases/01D'),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('database.title')), findsOneWidget);

        await tester.tap(find.byKey(const Key('database.close')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database.title')), findsNothing);
        expect(find.byKey(const Key('notes.title')), findsOneWidget);
      },
    );

    testWidgets('closing a desktop database returns to All notes', (
      tester,
    ) async {
      _setWindow(tester, const Size(1400, 900));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          final one = await _backendWithOneNote(request);
          if (one.statusCode != 404) return one;
          return _databaseBackend(request);
        }),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/databases/01D',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/databases/01D', router: router),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell.sidebar')), findsOneWidget);
      expect(find.byType(NotesListScreen), findsNothing);
      expect(_listRow(), findsNothing);
      expect(find.byKey(const Key('database.title')), findsOneWidget);

      await tester.tap(find.byKey(const Key('database.close')));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.toString(), '/');
      expect(find.byKey(const Key('database.title')), findsNothing);
      expect(find.byType(NotesListScreen), findsOneWidget);
    });
  });

  testWidgets(
    'desktop search and settings respect reduced motion',
    (tester) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          wrapContent: (child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 800),
              disableAnimations: true,
            ),
            child: child,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _pressChord(
        tester,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.keyK,
      );
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(SearchScreen)))!
            .transitionDuration,
        Duration.zero,
      );
      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();
      await _pressChord(
        tester,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.comma,
      );
      expect(
        ModalRoute.of(tester.element(find.byKey(const Key('account.sheet'))))!
            .transitionDuration,
        Duration.zero,
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'mobile search and settings skip motion when requested',
    (tester) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);
      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          wrapContent: (child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 800),
              disableAnimations: true,
            ),
            child: child,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _pressChord(
        tester,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.keyK,
      );
      expect(
        ModalRoute.of(tester.element(find.byType(SearchScreen)))!
            .transitionDuration,
        Duration.zero,
      );
      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();
      await _pressChord(
        tester,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.comma,
      );
      expect(find.byKey(const Key('account.server')), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byKey(const Key('account.sheet'))))!
            .transitionDuration,
        Duration.zero,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  group('search overlay', () {
    testWidgets('opens above the list rather than replacing it', (
      tester,
    ) async {
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes.title')), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell.search')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
      // The list is still in the tree underneath, not popped/replaced.
      expect(find.byKey(const Key('notes.title')), findsOneWidget);
    });

    testWidgets('is a palette dialog on a wide window, closed by its button', (
      tester,
    ) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell.search')));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const Key('search.input')), findsOneWidget);
      final paletteSize = tester.getSize(find.byType(SearchScreen));
      expect(paletteSize.width, lessThanOrEqualTo(640));
      expect(paletteSize.height, lessThanOrEqualTo(0.7 * 600));
      // Anchored near the top rather than vertically centered.
      expect(
        tester.getTopLeft(find.byType(SearchScreen)).dy,
        lessThan(600 / 2 - paletteSize.height / 2),
      );

      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('uses a Material bottom sheet on compact Android', (
      tester,
    ) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.getBottomLeft(find.byType(BottomSheet)).dy, 800);

      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsNothing);
    });

    testWidgets(
      'closing the overlay returns to the list without a fresh fetch',
      (tester) async {
        var listFetches = 0;
        final mock = MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/notes' &&
              request.url.queryParameters['include_subfolders'] != 'false') {
            listFetches += 1;
          }
          return _fakeBackend(request);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        addTearDown(api.close);

        await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
        await tester.pumpAndSettle();
        expect(listFetches, 1);

        await tester.tap(find.byKey(const Key('shell.search')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search.input')), findsOneWidget);

        // Dismiss via the scrim, like tapping outside a dialog.
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search.input')), findsNothing);
        expect(find.byKey(const Key('notes.title')), findsOneWidget);
        expect(listFetches, 1, reason: 'closing search should not refetch');
      },
    );

    testWidgets('on Android the search sheet can be swiped down '
        'dismisses without a fresh fetch', (tester) async {
      _setWindow(tester, const Size(400, 800));
      var listFetches = 0;
      final mock = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/notes' &&
            request.url.queryParameters['include_subfolders'] != 'false') {
          listFetches += 1;
        }
        return _fakeBackend(request);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(listFetches, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search.input')), findsOneWidget);
      final sheetTop = tester.getTopLeft(find.byType(BottomSheet));
      await tester.dragFrom(
        sheetTop + const Offset(200, 16),
        const Offset(0, 650),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsNothing);
      expect(find.byKey(const Key('notes.title')), findsOneWidget);
      expect(listFetches, 1, reason: 'closing search should not refetch');
    });

    testWidgets('a short drag on the handle springs the sheet back', (
      tester,
    ) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
      final sheetTop = tester.getTopLeft(find.byType(BottomSheet));
      final restingTop = tester.getTopLeft(find.byType(SearchScreen)).dy;

      await tester.timedDragFrom(
        sheetTop + const Offset(200, 16),
        const Offset(0, 30),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
      expect(tester.getTopLeft(find.byType(SearchScreen)).dy, restingTop);
    });

    testWidgets('the wide palette has no grab handle', (tester) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell.search')));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const Key('search.sheet.handle')), findsNothing);
    });
  });

  testWidgets('pushing to a note updates the reported URL', (tester) async {
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);

    final ws = RobotNotesWsClient(config: _config);
    final list = NotesListController(api: api);
    final tree = FolderTreeController(api: api);
    final databases = DatabasesController(api: api);
    final router = buildAppRouter(
      configHolder: ConfigHolder.seeded(_config),
      initialLocation: '/',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => AppSession(
          api: api,
          ws: ws,
          list: list,
          tree: tree,
          databases: databases,
          actor: _config.actor,
          baseUrl: _config.baseUrl,
          connection: ValueNotifier(ConnectionStatus.connected),
          onReset: () {},
          child: child!,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The notes list and search button both navigate with `context.push`
    // (an imperative API), which go_router 18 ignores for the reported URL
    // unless `optionURLReflectsImperativeAPIs` is set — without it, the
    // browser address bar stays on the previous route forever.
    unawaited(router.push('/notes/01H'));
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.toString(), '/notes/01H');
  });

  testWidgets(
    'closing a deep-linked note (no history) lands on the notes list',
    (tester) async {
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/notes/01H'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BlockNoteEditor), findsOneWidget);

      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();

      expect(find.byType(BlockNoteEditor), findsNothing);
      expect(find.byKey(const Key('notes.title')), findsOneWidget);
    },
  );

  for (final width in [840.0, 1000.0, 1200.0]) {
    testWidgets(
      'two-pane desktop at $width replaces the list when opening a note',
      (tester) async {
        _setWindow(tester, Size(width, 900));
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient(_backendWithOneNote),
        );
        addTearDown(api.close);
        final router = buildAppRouter(
          configHolder: ConfigHolder.seeded(_config),
          initialLocation: '/',
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/', router: router),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shell.sidebar')), findsOneWidget);
        await tester.tap(_listRow());
        await tester.pumpAndSettle();
        expect(find.byType(BlockNoteEditor), findsOneWidget);
        expect(find.byType(NotesListScreen), findsNothing);
        expect(find.byKey(const Key('shell.sidebar')), findsOneWidget);
      },
    );
  }

  group('two-pane shell (desktop window)', () {
    testWidgets(
      'failed save retains the draft and selection on folder activation',
      (tester) async {
        _setWindow(tester, const Size(1000, 800));
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/notes/01H') {
              return http.Response('unavailable', 500);
            }
            if (request.url.path == '/notes/tree') {
              return http.Response(
                jsonEncode({
                  'folders': [
                    {'path': 'Projects', 'note_count': 0},
                    {'path': '', 'note_count': 1},
                  ],
                }),
                200,
              );
            }
            return _backendWithOneNote(request);
          }),
        );
        addTearDown(api.close);
        final router = buildAppRouter(
          configHolder: ConfigHolder.seeded(_config),
          initialLocation: '/notes/01H?edit=1',
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _harness(
            api: api,
            initialLocation: '/notes/01H?edit=1',
            router: router,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note.menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note.source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('note.editor.content')),
          'Draft',
        );
        final controller = tester
            .widget<NoteScreen>(find.byType(NoteScreen))
            .controller;

        await tester.tap(find.byKey(const Key('sidebar.folder.Projects')));
        await tester.pumpAndSettle();

        expect(
          router.routeInformationProvider.value.uri.toString(),
          '/notes/01H?edit=1',
        );
        expect(
          tester.widget<NoteScreen>(find.byType(NoteScreen)).controller,
          same(controller),
        );
        expect(controller.value.editContent, 'Draft');
        expect(controller.value.isDirty, isTrue);
        expect(
          tester
              .widget<ListTile>(find.byKey(const Key('sidebar.note.01H')))
              .selected,
          isTrue,
        );
        expect(
          tester
              .widget<ListTile>(
                find.byKey(const Key('sidebar.folder.Projects')),
              )
              .selected,
          isFalse,
        );
        expect(find.byType(FolderOverview), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('folder breadcrumbs and files retain the browse destination', (
      tester,
    ) async {
      _setWindow(tester, const Size(1000, 800));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/tree') {
            return http.Response(
              jsonEncode({
                'folders': [
                  {'path': 'Projects/Alpha', 'note_count': 0},
                  {'path': '', 'note_count': 0, 'file_count': 1},
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/notes/files') {
            final root = request.url.queryParameters['path'] == '';
            return http.Response(
              jsonEncode({
                'items': root
                    ? [
                        {
                          'path': '',
                          'filename': 'notes & data.txt',
                          'size': 12,
                          'content_type': 'text/plain',
                          'updated_at': _now,
                        },
                      ]
                    : <Object?>[],
              }),
              200,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/',
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', router: router),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sidebar.folder.Projects')));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['folder'],
        'Projects',
      );
      expect(find.byType(FolderOverview), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('sidebar.overview.folder.Projects/Alpha')),
      );
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['folder'],
        'Projects/Alpha',
      );
      await tester.tap(find.byKey(const Key('overview.breadcrumb.0')));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['folder'],
        'Projects',
      );

      await tester.tap(find.byKey(const Key('overview.root')));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['folder'],
        '',
      );
      expect(find.byType(NotesListScreen), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(FolderOverview),
          matching: find.byKey(const Key('sidebar.file.notes & data.txt')),
        ),
      );
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/file');
      expect(
        router.routeInformationProvider.value.uri.queryParameters['path'],
        'notes & data.txt',
      );
      expect(find.byType(FileScreen), findsOneWidget);
      expect(find.text('text/plain'), findsOneWidget);
      await tester.tap(find.byTooltip('Close file'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['folder'],
        '',
      );
      expect(find.byType(FolderOverview), findsOneWidget);

      await tester.tap(find.byKey(const Key('overview.allNotes')));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.toString(), '/');
      expect(find.byType(NotesListScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing a later-page note restores list pages and scroll', (
      tester,
    ) async {
      _setWindow(tester, const Size(1000, 600));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes' &&
              request.url.queryParameters['include_subfolders'] != 'false') {
            final secondPage =
                request.url.queryParameters['after'] == 'page-one';
            return http.Response(
              jsonEncode({
                'items': secondPage
                    ? [_noteJson()]
                    : [
                        for (var index = 0; index < 30; index++)
                          _noteJson(id: 'note-$index', title: 'Note $index'),
                      ],
                'limit': 50,
                'next_cursor': secondPage ? null : 'page-one',
              }),
              200,
            );
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/',
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', router: router),
      );
      await tester.pumpAndSettle();
      final list = tester
          .widget<NotesListScreen>(find.byType(NotesListScreen))
          .controller;
      await list.loadMore();
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byType(NotesListScreen),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(_listRow(), 400, scrollable: scrollable);
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(offset, greaterThan(0));
      expect(list.value.items, hasLength(31));

      await tester.tap(_listRow());
      await tester.pumpAndSettle();
      expect(find.byType(NotesListScreen), findsNothing);
      await _closeNote(tester);

      expect(list.value.items, hasLength(31));
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 1),
      );
      expect(_listRow(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening a note replaces All notes and selects its tree row', (
      tester,
    ) async {
      _setWindow(tester, const Size(1400, 900));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(_backendWithOneNote),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', router: router),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell.sidebar')), findsOneWidget);
      expect(find.byKey(const Key('sidebar.allNotes')), findsOneWidget);
      expect(find.byType(NotesListScreen), findsOneWidget);
      expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
      expect(
        tester.getSize(find.byType(NotesListScreen)).width,
        greaterThan(PaneSizes.readingColumn),
      );
      expect(_listRow(), findsOneWidget);
      expect(
        tester
            .getSemantics(_listRow())
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );

      await tester.tap(_listRow());
      await tester.pumpAndSettle();

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/notes/01H',
      );
      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(find.text('world', findRichText: true), findsOneWidget);
      expect(find.byType(NotesListScreen), findsNothing);
      expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
      expect(
        tester.getTopLeft(find.byType(BlockNoteEditor)).dx,
        greaterThanOrEqualTo(PaneSizes.sidebarMin),
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('sidebar.note.01H')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      // Pane presentation: a close button rather than a back arrow, and
      // nothing was pushed (the shell replaced the detail pane).
      expect(
        find.descendant(
          of: find.byKey(const Key('note.close')),
          matching: find.byIcon(Icons.close),
        ),
        findsOneWidget,
      );
      expect(router.canPop(), isFalse);

      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.toString(), '/');
      expect(find.byType(BlockNoteEditor), findsNothing);
      expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
      expect(find.byType(NotesListScreen), findsOneWidget);
    });

    testWidgets('honours a macOS unified-title-bar inset from the ambient '
        'MediaQuery: the sidebar Material still starts at the top, but its '
        "'Vault' header and the notes list's app bar inset below it", (
      tester,
    ) async {
      _setWindow(tester, const Size(1400, 900));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(_backendWithOneNote),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(
          api: api,
          initialLocation: '/',
          wrapContent: (child) => Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(padding: media.padding.copyWith(top: 28)),
                child: child,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The sidebar's background still paints all the way up (under a
      // unified title bar's traffic lights)...
      expect(tester.getTopLeft(find.byKey(const Key('shell.sidebar'))).dy, 0);
      // ...but its content insets below the title-bar inset.
      expect(
        tester.getTopLeft(find.text('Vault')).dy,
        greaterThanOrEqualTo(28),
      );
      // The notes list pane's own AppBar (a Scaffold-hosted AppBar
      // already honours MediaQuery.padding.top) insets the same way.
      expect(
        tester.getTopLeft(find.byKey(const Key('notes.title'))).dy,
        greaterThanOrEqualTo(28),
      );
    });

    testWidgets(
      'a deep-linked note renders beside the tree with its row selected',
      (tester) async {
        _setWindow(tester, const Size(1400, 900));
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient(_backendWithOneNote),
        );
        addTearDown(api.close);

        await tester.pumpWidget(
          _harness(api: api, initialLocation: '/notes/01H'),
        );
        await tester.pumpAndSettle();

        expect(find.byType(BlockNoteEditor), findsOneWidget);
        expect(find.byType(NotesListScreen), findsNothing);
        expect(
          tester
              .getSemantics(find.byKey(const Key('sidebar.note.01H')))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
      },
    );

    testWidgets('the sidebar width survives navigating to a note', (
      tester,
    ) async {
      _setWindow(tester, const Size(1400, 900));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(_backendWithOneNote),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      final sidebar = find.byKey(const Key('shell.sidebar'));
      expect(tester.getSize(sidebar).width, PaneSizes.sidebarDefault);

      final handle = find.byKey(const Key('panel.resizeHandle'));
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, 0)); // crosses the drag slop
      await gesture.moveBy(const Offset(60, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      final widened = tester.getSize(sidebar).width;
      expect(widened, greaterThan(PaneSizes.sidebarDefault));

      await tester.tap(_listRow());
      await tester.pumpAndSettle();

      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(tester.getSize(sidebar).width, widened);
    });

    testWidgets('"New note" replaces the list with the editor', (tester) async {
      _setWindow(tester, const Size(1400, 900));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/notes') {
            return http.Response(jsonEncode(_noteJson()), 201);
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', router: router),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create.toolbar')));
      await tester.pumpAndSettle();

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/notes/01H?edit=1',
      );
      expect(find.byKey(const Key('note.editor.title')), findsOneWidget);
      expect(find.byType(NotesListScreen), findsNothing);
      expect(router.canPop(), isFalse);

      await _closeNote(tester);
    });
  });

  testWidgets('reduced motion opens notes without an animated route', (
    tester,
  ) async {
    _setWindow(tester, const Size(800, 600));
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient(_backendWithOneNote),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      _harness(
        api: api,
        initialLocation: '/',
        wrapContent: (child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            disableAnimations: true,
          ),
          child: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_listRow());
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(BlockNoteEditor)))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  });

  testWidgets('iOS notes support edge-swipe back to the list', (tester) async {
    _setWindow(tester, const Size(390, 844));
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient(_backendWithOneNote),
    );
    addTearDown(api.close);
    await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
    await tester.pumpAndSettle();
    await tester.tap(_listRow());
    await tester.pumpAndSettle();
    expect(find.byType(BlockNoteEditor), findsOneWidget);
    await tester.dragFrom(const Offset(1, 400), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(find.byType(NotesListScreen), findsOneWidget);
    expect(find.byType(BlockNoteEditor), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  group('stacked navigation below the desktop breakpoint', () {
    testWidgets('tapping a row pushes the note as a page over the list', (
      tester,
    ) async {
      _setWindow(tester, const Size(839, 600));
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(_backendWithOneNote),
      );
      addTearDown(api.close);
      final router = buildAppRouter(
        configHolder: ConfigHolder.seeded(_config),
        initialLocation: '/',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', router: router),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell.sidebar')), findsNothing);
      expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
      // The inline sidebar belongs to the list screen here.
      expect(find.byKey(const Key('sidebar.allNotes')), findsOneWidget);

      await tester.tap(_listRow());
      await tester.pumpAndSettle();

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/notes/01H',
      );
      expect(router.canPop(), isTrue);
      expect(find.byType(BlockNoteEditor), findsOneWidget);
      expect(find.byType(NotesListScreen), findsNothing);
      // Page presentation: a back arrow.
      expect(
        find.descendant(
          of: find.byKey(const Key('note.close')),
          matching: find.byIcon(Icons.arrow_back),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.toString(), '/');
      expect(find.byType(NotesListScreen), findsOneWidget);
    });
  });

  group('keyboard shortcuts', () {
    testWidgets('Cmd+K opens search', (tester) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search.input')), findsNothing);

      await _pressChord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyK,
      );

      expect(find.byKey(const Key('search.input')), findsOneWidget);
    });

    testWidgets('Ctrl+Shift+F opens search', (tester) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await _pressChord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyF,
        secondModifier: LogicalKeyboardKey.shiftLeft,
      );

      expect(find.byKey(const Key('search.input')), findsOneWidget);
    });

    testWidgets('Ctrl+N creates a note in the selected folder and opens it', (
      tester,
    ) async {
      _setWindow(tester, const Size(800, 600));
      Map<String, dynamic>? createBody;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/tree') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'folders': [
                  {'path': 'Projects', 'note_count': 1},
                ],
              }),
              200,
            );
          }
          if (request.method == 'POST' && request.url.path == '/notes') {
            createBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode(_noteJson()), 201);
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();

      await _pressChord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyN,
      );

      expect(createBody?['path'], 'Projects');
      expect(find.byKey(const Key('note.editor.title')), findsOneWidget);

      await _closeNote(tester);
    });

    testWidgets('shortcuts also fire from inside the open note', (
      tester,
    ) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/notes/01H'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BlockNoteEditor), findsOneWidget);

      await _pressChord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyK,
      );

      expect(find.byKey(const Key('search.input')), findsOneWidget);
    });
  });

  group('extra shortcuts', () {
    testWidgets('Cmd+R re-fetches the notes list', (tester) async {
      _setWindow(tester, const Size(800, 600));
      var listCalls = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/notes' &&
              request.url.queryParameters['include_subfolders'] != 'false') {
            listCalls++;
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(listCalls, 1);

      await _pressChord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyR,
      );
      await tester.pumpAndSettle();

      expect(listCalls, 2);
    });

    testWidgets('Ctrl+, opens the account surface', (tester) async {
      _setWindow(tester, const Size(800, 600));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account.sheet')), findsNothing);

      await _pressChord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.comma,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account.sheet')), findsOneWidget);
    });
  });

  group('macOS menu bar registration', () {
    testWidgets('the shell publishes its commands while mounted', (
      tester,
    ) async {
      _setWindow(tester, const Size(800, 600));
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      var listCalls = 0;
      Map<String, dynamic>? createBody;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/notes' &&
              request.url.queryParameters['include_subfolders'] != 'false') {
            listCalls++;
          }
          if (request.method == 'POST' && request.url.path == '/notes') {
            createBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode(_noteJson()), 201);
          }
          return _fakeBackend(request);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _harness(api: api, initialLocation: '/', menuActions: actions),
      );
      await tester.pumpAndSettle();

      expect(actions.shell.newNote, isNotNull);
      expect(actions.shell.newFolder, isNotNull);
      expect(actions.shell.uploadFile, isNotNull);
      expect(actions.shell.search, isNotNull);
      expect(actions.shell.refresh, isNotNull);
      expect(actions.shell.account, isNotNull);

      actions.shell.refresh!();
      await tester.pumpAndSettle();
      expect(listCalls, 2);

      actions.shell.search!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search.input')), findsOneWidget);
      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();

      actions.shell.newNote!();
      await tester.pumpAndSettle();
      expect(createBody, isNotNull);
      expect(find.byKey(const Key('note.editor.title')), findsOneWidget);

      await _closeNote(tester);
    });

    testWidgets('on the macOS desktop build the shell leaves menu-owned '
        'chords to the menu bar', (tester) async {
      // Reset inline (not in a tearDown): the test binding checks this
      // override is clear before tearDowns run.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        _setWindow(tester, const Size(800, 600));
        final api = RobotNotesClient(
          config: _config,
          httpClient: _mockClient(),
        );
        addTearDown(api.close);

        await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
        await tester.pumpAndSettle();

        final shortcuts = tester
            .widgetList<Shortcuts>(find.byType(Shortcuts))
            .map((w) => w.shortcuts)
            .firstWhere((m) => m.values.any((i) => i is OpenSearchIntent));
        expect(shortcuts.keys.any(menuOwnsShortcut), isFalse);
        // The non-menu spellings survive.
        expect(shortcuts.values, contains(const OpenSearchIntent()));
        expect(shortcuts.values, contains(const NewNoteIntent()));
        expect(nativeMenuBarActive, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
