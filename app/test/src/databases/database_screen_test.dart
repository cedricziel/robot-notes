import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/database_controller.dart';
import 'package:app/src/databases/database_screen.dart';
import 'package:app/src/databases/databases_controller.dart';
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

Map<String, Object?> _definitionJson({
  String id = '01A',
  String title = 'Projects',
  List<Object?>? views,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': 1,
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'properties': <String, Object?>{
    'status': <String, Object?>{
      'type': 'select',
      'options': ['Idea', 'Active', 'Done'],
    },
    'due': <String, Object?>{'type': 'date'},
  },
  'views':
      views ??
      <Object?>[
        <String, Object?>{
          'name': 'All',
          'type': 'table',
          'properties': ['status'],
        },
        <String, Object?>{
          'name': 'List',
          'type': 'list',
          'properties': ['status'],
        },
        <String, Object?>{
          'name': 'Kanban',
          'type': 'board',
          'group_by': 'status',
          'properties': ['due'],
        },
      ],
  'created_at': _now,
  'updated_at': _now,
};

Map<String, Object?> _rowJson({
  required String id,
  String title = 'Row',
  Map<String, Object?> properties = const {},
  List<String> invalid = const [],
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': 1,
  'created_at': _now,
  'updated_at': _now,
  'tags': <Object?>[],
  'properties': properties,
  'invalid': invalid,
};

/// Builds a real `DatabaseController` (via a seeded `DatabasesController`)
/// wired to a mock HTTP backend, plus the [DatabaseScreen] widget on top of
/// it, and pumps it through the initial load.
class _Harness {
  _Harness({
    Map<String, Object?>? definition,
    Future<http.Response> Function(http.Request)? query,
    void Function(String noteId)? onOpenRow,
  }) : definitionJson = definition ?? _definitionJson() {
    api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/databases/01A') {
          return http.Response(jsonEncode(definitionJson), 200);
        }
        if (request.method == 'POST' && path == '/databases/01A/query') {
          if (query != null) return query(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[],
              'next_cursor': null,
            }),
            200,
          );
        }
        if (request.method == 'PATCH' &&
            path.startsWith('/notes/') &&
            path.endsWith('/properties')) {
          patchRequests.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'id': '01R',
              'title': 'r1',
              'content': '',
              'version': 2,
              'created_at': _now,
              'updated_at': _now,
            }),
            200,
          );
        }
        if (request.method == 'POST' && path == '/databases/01A/rows') {
          createRowRequests.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'id': '01NEW',
              'title': jsonDecode(request.body)['title'],
              'content': '',
              'version': 1,
              'created_at': _now,
              'updated_at': _now,
            }),
            201,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    databases = DatabasesController(api: api);
    controller = DatabaseController(
      api: api,
      databases: databases,
      databaseId: '01A',
    );
    lastOpenedRow = null;
    screen = MaterialApp(
      home: DatabaseScreen(
        controller: controller,
        onOpenRow: onOpenRow ?? (id) => lastOpenedRow = id,
      ),
    );
  }

  final Map<String, Object?> definitionJson;
  late final RobotNotesClient api;
  late final DatabasesController databases;
  late final DatabaseController controller;
  late final Widget screen;
  String? lastOpenedRow;
  final List<http.Request> patchRequests = [];
  final List<http.Request> createRowRequests = [];

  void dispose() {
    controller.dispose();
    databases.dispose();
    api.close();
  }
}

void main() {
  group('DatabaseScreen', () {
    testWidgets('shows a loading spinner then the definition title', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.screen);
      expect(find.byKey(const Key('database.loading')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Projects'), findsOneWidget);
    });

    testWidgets('not-found renders the empty state', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(
          (request) async => http.Response('not found', 404),
        ),
      );
      addTearDown(api.close);
      final databases = DatabasesController(api: api);
      final controller = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(controller.dispose);
      addTearDown(databases.dispose);

      await tester.pumpWidget(
        MaterialApp(home: DatabaseScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database.notFound')), findsOneWidget);
    });

    testWidgets('table view renders Title + view columns in order', (
      tester,
    ) async {
      final h = _Harness(
        query: (request) async => http.Response(
          jsonEncode(<String, Object?>{
            'items': [
              _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
            ],
            'next_cursor': null,
          }),
          200,
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      expect(find.text('status'), findsOneWidget);
      expect(find.text('r1'), findsOneWidget);
      expect(find.text('Idea'), findsOneWidget);
    });

    testWidgets('table cell invalid values are highlighted', (tester) async {
      final h = _Harness(
        query: (request) async => http.Response(
          jsonEncode(<String, Object?>{
            'items': [
              _rowJson(
                id: '01R',
                title: 'r1',
                properties: {'status': 'Bogus'},
                invalid: ['status'],
              ),
            ],
            'next_cursor': null,
          }),
          200,
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('database.table.row.01R.status.invalid')),
        findsOneWidget,
      );
    });

    testWidgets(
      'editing a table cell sends PATCH /notes/{id}/properties with set',
      (tester) async {
        final h = _Harness(
          query: (request) async => http.Response(
            jsonEncode(<String, Object?>{
              'items': [
                _rowJson(
                  id: '01R',
                  title: 'r1',
                  properties: {'status': 'Idea'},
                ),
              ],
              'next_cursor': null,
            }),
            200,
          ),
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(h.screen);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('cell.status.tap')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('cell.editor.input')),
          'Active',
        );
        await tester.tap(find.byKey(const Key('cell.editor.save')));
        await tester.pumpAndSettle();

        expect(h.patchRequests.single.url.path, '/notes/01R/properties');
        expect(
          jsonDecode(h.patchRequests.single.body) as Map<String, Object?>,
          {
            'set': {'status': 'Active'},
          },
        );
        expect(find.text('Active'), findsOneWidget);
      },
    );

    testWidgets('clearing a cell sends unset', (tester) async {
      final h = _Harness(
        query: (request) async => http.Response(
          jsonEncode(<String, Object?>{
            'items': [
              _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
            ],
            'next_cursor': null,
          }),
          200,
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cell.status.tap')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cell.editor.clear')));
      await tester.pumpAndSettle();

      expect(jsonDecode(h.patchRequests.single.body) as Map<String, Object?>, {
        'unset': ['status'],
      });
    });

    testWidgets('tapping a row title opens the note', (tester) async {
      final h = _Harness(
        query: (request) async => http.Response(
          jsonEncode(<String, Object?>{
            'items': [_rowJson(id: '01R', title: 'r1')],
            'next_cursor': null,
          }),
          200,
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('database.table.row.01R.title')));
      await tester.pumpAndSettle();

      expect(h.lastOpenedRow, '01R');
    });

    testWidgets('switching views calls onViewChanged with the resolved name', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      String? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: DatabaseScreen(
            controller: h.controller,
            onViewChanged: (name) => changed = name,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(changed, 'All');

      await tester.tap(find.byKey(const Key('database.view.List')));
      await tester.pumpAndSettle();

      expect(changed, 'List');
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const Key('database.view.List')),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('list view renders rows with property chips', (tester) async {
      final h = _Harness(
        query: (request) async => http.Response(
          jsonEncode(<String, Object?>{
            'items': [
              _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
            ],
            'next_cursor': null,
          }),
          200,
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();
      await h.controller.selectView('List');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database.list.row.01R')), findsOneWidget);
      expect(find.text('Idea'), findsOneWidget);
    });

    testWidgets(
      'board view renders option columns in order with counts, plus No value',
      (tester) async {
        final h = _Harness(
          query: (request) async {
            final body = jsonDecode(request.body) as Map<String, Object?>;
            if (body['group_by'] != null) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'items': <Object?>[],
                  'next_cursor': null,
                  'groups': [
                    {'value': 'Idea', 'count': 2},
                    {'value': 'Active', 'count': 3},
                    {'value': 'Done', 'count': 0},
                    {'value': null, 'count': 1},
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'items': <Object?>[],
                'next_cursor': null,
              }),
              200,
            );
          },
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(h.screen);
        await tester.pumpAndSettle();
        await h.controller.selectView('Kanban');
        await tester.pumpAndSettle();

        expect(find.text('Idea (2)'), findsOneWidget);
        expect(find.text('Active (3)'), findsOneWidget);
        expect(find.text('Done (0)'), findsOneWidget);
        expect(find.text('No value (1)'), findsOneWidget);
      },
    );

    testWidgets('New row prompts for a title, creates it, and opens the note', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('database.newRow')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database.newRow.input')),
        'A new row',
      );
      await tester.tap(find.byKey(const Key('database.newRow.confirm')));
      await tester.pumpAndSettle();

      expect(h.createRowRequests.single.url.path, '/databases/01A/rows');
      expect(
        jsonDecode(h.createRowRequests.single.body) as Map<String, Object?>,
        containsPair('title', 'A new row'),
      );
      expect(h.lastOpenedRow, '01NEW');
    });

    testWidgets('the schema editor action fires its callback (stub)', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: DatabaseScreen(
            controller: h.controller,
            onOpenSchemaEditor: () => tapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('database.schemaEditor')));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('empty state renders when a view has no rows', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(h.screen);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database.empty')), findsOneWidget);
    });

    testWidgets('error mode shows a retry strip', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/databases/01A') {
            return http.Response(jsonEncode(_definitionJson()), 200);
          }
          return http.Response('boom', 500);
        }),
      );
      addTearDown(api.close);
      final databases = DatabasesController(api: api);
      final controller = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(controller.dispose);
      addTearDown(databases.dispose);

      await tester.pumpWidget(
        MaterialApp(home: DatabaseScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
