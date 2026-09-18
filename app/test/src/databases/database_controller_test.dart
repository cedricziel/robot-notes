import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/database_controller.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
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

Map<String, Object?> _definitionJson({
  String id = '01A',
  String title = 'Projects',
  int version = 1,
  List<Object?>? views,
  Map<String, Object?>? properties,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': version,
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'properties':
      properties ??
      <String, Object?>{
        'status': <String, Object?>{
          'type': 'select',
          'options': ['Idea', 'Active', 'Done'],
        },
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
          'name': 'Kanban',
          'type': 'board',
          'group_by': 'status',
        },
      ],
  'created_at': _now,
  'updated_at': _now,
};

Map<String, Object?> _rowJson({
  required String id,
  String title = 'Row',
  Map<String, Object?> properties = const {},
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': 1,
  'created_at': _now,
  'updated_at': _now,
  'tags': <Object?>[],
  'properties': properties,
  'invalid': <Object?>[],
};

http.Response _pageJson(List<Object?> items, {String? nextCursor}) =>
    http.Response(
      jsonEncode(<String, Object?>{'items': items, 'next_cursor': nextCursor}),
      200,
    );

/// A [DatabasesController] pre-seeded with [definition] via a mock so
/// `DatabaseController.load()` hits the cache path immediately.
Future<DatabasesController> _seededDatabases(
  Map<String, Object?> definitionJson,
) async {
  final api = RobotNotesClient(
    config: _config,
    httpClient: MockClient(
      (request) async => http.Response(jsonEncode(definitionJson), 200),
    ),
  );
  final databases = DatabasesController(api: api);
  await databases.definition(definitionJson['id'] as String);
  return databases;
}

void main() {
  group('DatabaseController', () {
    test('load() resolves the default view and queries it', () async {
      final databases = await _seededDatabases(_definitionJson());
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}?${request.url.query}');
        return _pageJson([
          _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();

      expect(ctrl.value.mode, DatabaseScreenMode.ready);
      expect(ctrl.value.viewName, 'All');
      expect(ctrl.value.rows.single.title, 'r1');
      expect(calls.single, contains('/databases/01A/query'));
    });

    test('load() surfaces a 404 as notFound', () async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(
          (request) async => http.Response('not found', 404),
        ),
      );
      final databases = DatabasesController(api: api);
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();

      expect(ctrl.value.mode, DatabaseScreenMode.notFound);
    });

    test('an unknown initial view falls back to the first view', () async {
      final databases = await _seededDatabases(_definitionJson());
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => _pageJson(const [])),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
        initialView: 'Nope',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();

      expect(ctrl.value.viewName, 'All');
    });

    test('selectView switches and re-queries', () async {
      final databases = await _seededDatabases(_definitionJson());
      final queriedViews = <String?>[];
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/query')) {
            queriedViews.add(body['view'] as String?);
          }
          return _pageJson(const []);
        }),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();
      await ctrl.selectView('Kanban');

      expect(ctrl.value.viewName, 'Kanban');
      // load() queries "All" (flat), then selectView switches to "Kanban"
      // (board) which issues its own group-count + per-column queries —
      // none of which use the `view` query param.
      expect(queriedViews.first, 'All');
    });

    test('loadMore appends the next page and keeps the cursor', () async {
      final databases = await _seededDatabases(_definitionJson());
      var page = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          page += 1;
          return page == 1
              ? _pageJson([
                  _rowJson(id: '01R', title: 'first'),
                ], nextCursor: 'cursor-2')
              : _pageJson([_rowJson(id: '02R', title: 'second')]);
        }),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();
      expect(ctrl.value.hasMore, isTrue);
      await ctrl.loadMore();

      expect(ctrl.value.rows.map((r) => r.title), ['first', 'second']);
      expect(ctrl.value.hasMore, isFalse);
    });

    test('board view builds columns in option order plus No value, with '
        'counts from groups', () async {
      final databases = await _seededDatabases(
        _definitionJson(
          views: [
            {'name': 'Kanban', 'type': 'board', 'group_by': 'status'},
          ],
        ),
      );
      final calls = <Map<String, Object?>>[];
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          calls.add(body);
          if (body['group_by'] != null) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'items': <Object?>[],
                'next_cursor': null,
                'groups': <Object?>[
                  {'value': 'Idea', 'count': 2},
                  {'value': 'Active', 'count': 3},
                  {'value': null, 'count': 1},
                ],
              }),
              200,
            );
          }
          final filter = body['filter'] as Map<String, dynamic>;
          final value = filter['value'];
          if (filter['op'] == 'eq' && value == 'Idea') {
            return _pageJson([_rowJson(id: '01R', title: 'idea-row')]);
          }
          if (filter['op'] == 'eq' && value == 'Active') {
            return _pageJson([_rowJson(id: '02R', title: 'active-row')]);
          }
          return _pageJson(const []);
        }),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();

      final columns = ctrl.value.columns!;
      expect(columns.map((c) => c.label), [
        'Idea',
        'Active',
        'Done',
        'No value',
      ]);
      expect(columns[0].count, 2);
      expect(columns[1].count, 3);
      expect(columns[2].count, 0);
      expect(columns[3].count, 1);
      expect(columns[0].items.single.title, 'idea-row');
      expect(columns[1].items.single.title, 'active-row');
    });

    test('board column pages independently via loadMoreColumn', () async {
      final databases = await _seededDatabases(
        _definitionJson(
          views: [
            {'name': 'Kanban', 'type': 'board', 'group_by': 'status'},
          ],
        ),
      );
      var activePage = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['group_by'] != null) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'items': <Object?>[],
                'next_cursor': null,
                'groups': <Object?>[
                  {'value': 'Active', 'count': 2},
                ],
              }),
              200,
            );
          }
          final filter = body['filter'] as Map<String, dynamic>;
          if (filter['value'] == 'Active') {
            activePage += 1;
            if (activePage == 1) {
              return _pageJson([
                _rowJson(id: '01R', title: 'a1'),
              ], nextCursor: 'more');
            }
            return _pageJson([_rowJson(id: '02R', title: 'a2')]);
          }
          return _pageJson(const []);
        }),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();
      final activeCol = ctrl.value.columns!.firstWhere(
        (c) => c.value == 'Active',
      );
      expect(activeCol.items.map((r) => r.title), ['a1']);
      expect(activeCol.hasMore, isTrue);

      await ctrl.loadMoreColumn('Active');

      final updated = ctrl.value.columns!.firstWhere(
        (c) => c.value == 'Active',
      );
      expect(updated.items.map((r) => r.title), ['a1', 'a2']);
      expect(updated.hasMore, isFalse);
    });

    test(
      'patchProperty sends the patch and applies it optimistically',
      () async {
        final databases = await _seededDatabases(_definitionJson());
        final patches = <Map<String, dynamic>>[];
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient((request) async {
            if (request.method == 'PATCH') {
              patches.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(
                jsonEncode(<String, Object?>{
                  'id': '01R',
                  'title': 'r1',
                  'path': '',
                  'content': '',
                  'version': 2,
                  'created_at': _now,
                  'updated_at': _now,
                  'tags': <Object?>[],
                  'properties': <String, Object?>{'status': 'Active'},
                }),
                200,
              );
            }
            return _pageJson([
              _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
            ]);
          }),
        );
        final ctrl = DatabaseController(
          api: api,
          databases: databases,
          databaseId: '01A',
        );
        addTearDown(ctrl.dispose);

        await ctrl.load();
        await ctrl.patchProperty('01R', set: {'status': 'Active'});

        expect(patches.single['set'], {'status': 'Active'});
        expect(ctrl.value.rows.single.properties['status'], 'Active');
      },
    );

    test('a rejected patch reverts the optimistic value', () async {
      final databases = await _seededDatabases(_definitionJson());
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'PATCH') {
            return http.Response(
              jsonEncode({'error': 'validation_failed', 'message': 'bad'}),
              400,
            );
          }
          return _pageJson([
            _rowJson(id: '01R', title: 'r1', properties: {'status': 'Idea'}),
          ]);
        }),
      );
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
      );
      addTearDown(ctrl.dispose);

      await ctrl.load();
      await ctrl.patchProperty('01R', set: {'status': 'Active'});

      expect(ctrl.value.rows.single.properties['status'], 'Idea');
      expect(ctrl.value.error, isNotNull);
    });

    test('a row that leaves the view after a patch is removed on the next '
        're-query with an undo notice', () async {
      final databases = await _seededDatabases(
        _definitionJson(
          views: [
            {
              'name': 'Active only',
              'type': 'table',
              'filter': {'property': 'status', 'op': 'eq', 'value': 'Active'},
            },
          ],
        ),
      );
      var queryCount = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'PATCH') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'id': '01R',
                'title': 'r1',
                'path': '',
                'content': '',
                'version': 2,
                'created_at': _now,
                'updated_at': _now,
                'tags': <Object?>[],
                'properties': <String, Object?>{'status': 'Done'},
              }),
              200,
            );
          }
          queryCount += 1;
          // First query: the row is present (Active). After the patch,
          // the server now excludes it (it's Done, not Active).
          return queryCount == 1
              ? _pageJson([
                  _rowJson(
                    id: '01R',
                    title: 'r1',
                    properties: {'status': 'Active'},
                  ),
                ])
              : _pageJson(const []);
        }),
      );
      final events = StreamController<RealtimeEvent>();
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
        events: events.stream,
        debounceScheduler: (_) async {},
      );
      addTearDown(ctrl.dispose);
      addTearDown(events.close);

      await ctrl.load();
      await ctrl.patchProperty('01R', set: {'status': 'Done'});
      // Row stays in place until the next re-query.
      expect(ctrl.value.rows.single.id, '01R');

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01R',
            version: 2,
            by: 'cedric',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.rows, isEmpty);
      expect(ctrl.value.leftViewNotice, isNotNull);
      expect(ctrl.value.leftViewNotice!.noteId, '01R');
    });

    test('undoLeftView re-patches the previous value', () async {
      final databases = await _seededDatabases(
        _definitionJson(
          views: [
            {
              'name': 'Active only',
              'type': 'table',
              'filter': {'property': 'status', 'op': 'eq', 'value': 'Active'},
            },
          ],
        ),
      );
      final patches = <Map<String, dynamic>>[];
      var queryCount = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.method == 'PATCH') {
            patches.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode(<String, Object?>{
                'id': '01R',
                'title': 'r1',
                'path': '',
                'content': '',
                'version': patches.length + 1,
                'created_at': _now,
                'updated_at': _now,
                'tags': <Object?>[],
                'properties': <String, Object?>{},
              }),
              200,
            );
          }
          queryCount += 1;
          return queryCount == 1
              ? _pageJson([
                  _rowJson(
                    id: '01R',
                    title: 'r1',
                    properties: {'status': 'Active'},
                  ),
                ])
              : _pageJson(const []);
        }),
      );
      final events = StreamController<RealtimeEvent>();
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
        events: events.stream,
        debounceScheduler: (_) async {},
      );
      addTearDown(ctrl.dispose);
      addTearDown(events.close);

      await ctrl.load();
      await ctrl.patchProperty('01R', set: {'status': 'Done'});

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01R',
            version: 2,
            by: 'cedric',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.value.leftViewNotice, isNotNull);

      await ctrl.undoLeftView();

      expect(patches.last['set'], {'status': 'Active'});
      expect(ctrl.value.leftViewNotice, isNull);
    });

    test('a changed event debounces re-query to at most 1/s', () async {
      final databases = await _seededDatabases(_definitionJson());
      var queries = 0;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          queries += 1;
          return _pageJson(const []);
        }),
      );
      final events = StreamController<RealtimeEvent>();
      final scheduledDelays = <Duration>[];
      final gates = <Completer<void>>[];
      final ctrl = DatabaseController(
        api: api,
        databases: databases,
        databaseId: '01A',
        events: events.stream,
        debounceScheduler: (d) async {
          scheduledDelays.add(d);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
        },
      );
      addTearDown(ctrl.dispose);
      addTearDown(events.close);

      await ctrl.load();
      expect(queries, 1);

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01R',
            version: 2,
            by: 'agent',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(scheduledDelays, [const Duration(seconds: 1)]);
      expect(queries, 1);

      gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(queries, 2);
    });
  });
}
