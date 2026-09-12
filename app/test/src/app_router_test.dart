import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
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
MockClient _mockClient() => MockClient((request) async {
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
});

/// Router-level test harness: a real [GoRouter] from [buildAppRouter], but
/// wrapped in a hand-rolled [AppSession] instead of the production
/// [SessionHost] so the test owns the [RobotNotesWsClient] and never starts
/// a real socket connection.
Widget _harness({
  required RobotNotesClient api,
  required String initialLocation,
}) {
  final ws = RobotNotesWsClient(config: _config);
  final list = NotesListController(api: api);
  final tree = FolderTreeController(api: api);
  final router = buildAppRouter(
    configHolder: ConfigHolder.seeded(_config),
    initialLocation: initialLocation,
  );
  return MaterialApp.router(
    routerConfig: router,
    builder: (context, child) => AppSession(
      api: api,
      ws: ws,
      list: list,
      tree: tree,
      actor: _config.actor,
      onReset: () {},
      child: child!,
    ),
  );
}

void main() {
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

  testWidgets('/search shows the search screen', (tester) async {
    final api = RobotNotesClient(config: _config, httpClient: _mockClient());
    addTearDown(api.close);

    await tester.pumpWidget(_harness(api: api, initialLocation: '/search'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search.input')), findsOneWidget);
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
}
