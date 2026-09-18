import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/desktop/app_menu_actions.dart';
import 'package:app/src/desktop/app_menu_bar.dart';
import 'package:app/src/files/picked_file.dart';
import 'package:app/src/layout/breakpoints.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/notes_list_screen.dart';
import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:app/src/search/search_screen.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  if (method == 'GET' && path == '/notes/tree') {
    return http.Response(jsonEncode(<String, Object?>{'folders': []}), 200);
  }
  return http.Response('not found', 404);
}

MockClient _mockClient() => MockClient(_fakeBackend);

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
}) {
  final ws = RobotNotesWsClient(config: _config);
  final list = NotesListController(api: api);
  final tree = FolderTreeController(api: api);
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
      actor: _config.actor,
      baseUrl: _config.baseUrl,
      connection: connection ?? ValueNotifier(ConnectionStatus.connected),
      onReset: onReset ?? () {},
      child: child!,
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

/// Closes an open note (through the discard prompt if the editor is
/// dirty) and lets its lock heartbeat timer elapse, so a test that opened
/// the editor ends with nothing pending.
Future<void> _closeNoteAndDrainTimers(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('note.close')));
  await tester.pumpAndSettle();
  final discardConfirm = find.byKey(const Key('note.discard.confirm'));
  if (discardConfirm.evaluate().isNotEmpty) {
    await tester.tap(discardConfirm);
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(days: 365 * 100));
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
  matching: find.text('hello'),
);

void main() {
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

    await tester.tap(find.byKey(const Key('notes.create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notes.create.note')));
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

      // The sidebar lives in a drawer on this narrow layout; open it to
      // select a folder, then dismiss it (tapping the scrim) so the FAB
      // underneath is reachable again.
      await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(390, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.create')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.create.upload')));
      await tester.pumpAndSettle();

      expect(capturedFields?['path'], 'Projects/Alpha');
      expect(capturedFields?['filename'], 'diagram.png');
      expect(find.text('Uploaded diagram.png'), findsOneWidget);
    });

    testWidgets('cancelling the file picker sends no request', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var uploadRequested = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/files') {
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

      await tester.tap(find.byKey(const Key('notes.create')));
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

      await tester.tap(find.byKey(const Key('notes.create')));
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

      await tester.tap(find.byKey(const Key('notes.bottomNav.search')));
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

      await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
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

        await tester.tap(find.byKey(const Key('notes.bottomNav.account')));
        await tester.pumpAndSettle();

        // Compact: a bottom sheet, not a dialog.
        expect(find.byKey(const Key('account.sheet')), findsOneWidget);
        expect(find.byType(BottomSheet), findsOneWidget);
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

        expect(find.byKey(const Key('account.sheet')), findsNothing);
        expect(find.text('Disconnect from server?'), findsOneWidget);
        expect(wasReset, isFalse);

        await tester.tap(find.byKey(const Key('account.disconnect.confirm')));
        await tester.pumpAndSettle();

        expect(wasReset, isTrue);
      },
    );

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

      await tester.tap(find.byKey(const Key('notes.bottomNav.account')));
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

    await tester.tap(find.byKey(const Key('notes.create.toolbar')));
    await tester.pumpAndSettle();

    expect(createBody?['path'], 'Projects/Alpha');

    // Creating navigates into the editor, which starts a real lock
    // heartbeat timer; stop it so the test ends with nothing pending.
    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(days: 365 * 100));
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

      // Creating navigates into the editor, which starts a real lock
      // heartbeat timer; stop it so the test ends with nothing pending.
      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(days: 365 * 100));
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

      await tester.tap(find.byKey(const Key('notes.create')));
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
      await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
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

      await tester.tap(find.byKey(const Key('notes.create')));
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

    expect(find.byKey(const Key('note.body')), findsOneWidget);
    expect(find.text('world'), findsOneWidget);
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

    // The lock heartbeat is a real timer; stop it by closing the note (via
    // the discard-changes prompt, since entering edit mode alone counts as
    // dirty) so the test ends with nothing pending.
    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();
    final discardConfirm = find.byKey(const Key('note.discard.confirm'));
    if (discardConfirm.evaluate().isNotEmpty) {
      await tester.tap(discardConfirm);
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(days: 365 * 100));
  });

  group('search overlay', () {
    testWidgets('opens above the list rather than replacing it', (
      tester,
    ) async {
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      expect(find.text('Notes'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell.search')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
      // The list is still in the tree underneath, not popped/replaced.
      expect(find.text('Notes'), findsOneWidget);
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

    testWidgets('is a top sheet, not a dialog, on a compact window', (
      tester,
    ) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('notes.bottomNav.search')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // Anchored to the top edge of the window.
      expect(
        tester.getTopLeft(find.byKey(const Key('search.input'))).dy,
        lessThan(100),
      );

      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search.input')), findsNothing);
    });

    testWidgets(
      'closing the overlay returns to the list without a fresh fetch',
      (tester) async {
        var listFetches = 0;
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes') {
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
        expect(find.text('Notes'), findsOneWidget);
        expect(listFetches, 1, reason: 'closing search should not refetch');
      },
    );

    testWidgets(
      'on a compact window the sheet has a grab handle; swiping it up '
      'dismisses without a fresh fetch',
      (tester) async {
        _setWindow(tester, const Size(400, 800));
        var listFetches = 0;
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes') {
            listFetches += 1;
          }
          return _fakeBackend(request);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        addTearDown(api.close);

        await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
        await tester.pumpAndSettle();
        expect(listFetches, 1);

        await tester.tap(find.byKey(const Key('notes.bottomNav.search')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search.input')), findsOneWidget);
        final handle = find.byKey(const Key('search.sheet.handle'));
        expect(handle, findsOneWidget);
        // The handle sits directly under the search content, along the
        // sheet's bottom edge (0.92 of the 800px window).
        expect(
          tester.getTopLeft(handle).dy,
          moreOrLessEquals(tester.getBottomLeft(find.byType(SearchScreen)).dy),
        );
        expect(tester.getBottomLeft(handle).dy, moreOrLessEquals(0.92 * 800));

        // Well past the 40% dismiss threshold of a 0.92 * 800 sheet.
        await tester.drag(handle, const Offset(0, -450));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search.input')), findsNothing);
        expect(find.text('Notes'), findsOneWidget);
        expect(listFetches, 1, reason: 'closing search should not refetch');
      },
    );

    testWidgets('a short drag on the handle springs the sheet back', (
      tester,
    ) async {
      _setWindow(tester, const Size(400, 800));
      final api = RobotNotesClient(config: _config, httpClient: _mockClient());
      addTearDown(api.close);

      await tester.pumpWidget(_harness(api: api, initialLocation: '/'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notes.bottomNav.search')));
      await tester.pumpAndSettle();
      final handle = find.byKey(const Key('search.sheet.handle'));
      final restingTop = tester.getTopLeft(find.byType(SearchScreen)).dy;

      await tester.drag(handle, const Offset(0, -60));
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
      expect(find.byKey(const Key('note.body')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note.close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note.body')), findsNothing);
      expect(find.text('Notes'), findsOneWidget);
    },
  );

  group('three-pane shell (large window)', () {
    testWidgets(
      'renders folders, the list and an empty detail pane; tapping a row '
      'opens the note beside the list with the row selected',
      (tester) async {
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
        expect(find.byKey(const Key('shell.detail.empty')), findsOneWidget);
        expect(find.text('Select a note'), findsOneWidget);
        expect(
          tester.getSize(find.byType(NotesListScreen)).width,
          PaneSizes.listPane,
        );
        expect(_listRow(), findsOneWidget);
        expect(
          tester
              .widget<ListTile>(
                find.ancestor(of: _listRow(), matching: find.byType(ListTile)),
              )
              .selected,
          isFalse,
        );

        await tester.tap(_listRow());
        await tester.pumpAndSettle();

        expect(
          router.routeInformationProvider.value.uri.toString(),
          '/notes/01H',
        );
        // The note renders in the detail pane, beside the still-mounted list.
        expect(find.byKey(const Key('note.body')), findsOneWidget);
        expect(find.text('world'), findsOneWidget);
        expect(find.byType(NotesListScreen), findsOneWidget);
        expect(find.byKey(const Key('shell.detail.empty')), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const Key('note.body'))).dx,
          greaterThan(PaneSizes.listPane + PaneSizes.sidebarMin),
        );
        expect(
          tester
              .widget<ListTile>(
                find.ancestor(of: _listRow(), matching: find.byType(ListTile)),
              )
              .selected,
          isTrue,
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
        expect(find.byKey(const Key('note.body')), findsNothing);
        expect(find.byKey(const Key('shell.detail.empty')), findsOneWidget);
        expect(find.byType(NotesListScreen), findsOneWidget);
      },
    );

    testWidgets('a deep-linked note renders beside the list', (tester) async {
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

      expect(find.byKey(const Key('note.body')), findsOneWidget);
      expect(find.byType(NotesListScreen), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.ancestor(of: _listRow(), matching: find.byType(ListTile)),
            )
            .selected,
        isTrue,
      );
    });

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

      expect(find.byKey(const Key('note.body')), findsOneWidget);
      expect(tester.getSize(sidebar).width, widened);
    });

    testWidgets('"New note" opens the editor in the detail pane', (
      tester,
    ) async {
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
      expect(find.byType(NotesListScreen), findsOneWidget);
      expect(router.canPop(), isFalse);

      await _closeNoteAndDrainTimers(tester);
    });
  });

  group('single-pane below the large breakpoint', () {
    testWidgets('tapping a row pushes the note as a page over the list', (
      tester,
    ) async {
      _setWindow(tester, const Size(800, 600));
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
      expect(find.byKey(const Key('note.body')), findsOneWidget);
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

      await _closeNoteAndDrainTimers(tester);
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
      expect(find.byKey(const Key('note.body')), findsOneWidget);

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
          if (request.method == 'GET' && request.url.path == '/notes') {
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
          if (request.method == 'GET' && request.url.path == '/notes') {
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

      await _closeNoteAndDrainTimers(tester);
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
