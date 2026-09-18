import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/database_embed.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter/material.dart';
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

Map<String, Object?> _summaryJson({
  required String id,
  required String title,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'row_count': 2,
};

Map<String, Object?> _definitionJson({
  required String id,
  required String title,
  List<Map<String, Object?>>? views,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': 1,
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'properties': <String, Object?>{
    'status': <String, Object?>{
      'type': 'select',
      'options': ['todo', 'done'],
    },
  },
  'views':
      views ??
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'All',
          'type': 'table',
          'properties': ['status'],
        },
      ],
  'created_at': _now,
  'updated_at': _now,
};

Map<String, Object?> _rowJson({
  required String id,
  required String title,
  Map<String, Object?> properties = const {},
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': 1,
  'created_at': _now,
  'updated_at': _now,
  'tags': <String>[],
  'properties': properties,
  'invalid': <String>[],
};

Future<void> _pump(
  WidgetTester tester, {
  required String title,
  String? view,
  http.Response Function(http.Request)? onQuery,
  List<DatabaseSummary> items = const [],
  Stream<RealtimeEvent>? events,
  Future<void> Function(Duration)? debounceScheduler,
  ValueChanged<String>? onOpenNote,
  void Function(String, String)? onShowAll,
}) async {
  final mock = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/databases/db1') {
      return http.Response(
        jsonEncode(_definitionJson(id: 'db1', title: 'Projects')),
        200,
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/databases/db1/query') {
      return onQuery?.call(request) ??
          http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                _rowJson(
                  id: 'n1',
                  title: 'Row one',
                  properties: {'status': 'todo'},
                ),
              ],
              'next_cursor': null,
            }),
            200,
          );
    }
    return http.Response('unexpected', 500);
  });
  final api = RobotNotesClient(config: _config, httpClient: mock);
  final databases = DatabasesController(api: api);
  databases.value = databases.value.copyWith(items: items);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DatabaseEmbed(
          title: title,
          view: view,
          databases: databases,
          api: api,
          events: events,
          debounceScheduler: debounceScheduler,
          onOpenNote: onOpenNote,
          onShowAll: onShowAll,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DatabaseEmbed', () {
    testWidgets('resolves the title and renders the default view as a table', (
      tester,
    ) async {
      await _pump(
        tester,
        title: 'projects', // case-insensitive
        items: [
          DatabaseSummary.fromJson(_summaryJson(id: 'db1', title: 'Projects')),
        ],
      );

      expect(find.byKey(const Key('database.embed.title')), findsOneWidget);
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Row one'), findsOneWidget);
    });

    testWidgets('an unresolvable title renders the literal source text', (
      tester,
    ) async {
      await _pump(tester, title: 'Nothing Here', items: const []);

      expect(find.byKey(const Key('database.embed.literal')), findsOneWidget);
      expect(find.text('![[Nothing Here]]'), findsOneWidget);
    });

    testWidgets('an unresolvable view renders the literal source text', (
      tester,
    ) async {
      await _pump(
        tester,
        title: 'Projects',
        view: 'NoSuchView',
        items: [
          DatabaseSummary.fromJson(_summaryJson(id: 'db1', title: 'Projects')),
        ],
      );

      expect(find.byKey(const Key('database.embed.literal')), findsOneWidget);
      expect(find.text('![[Projects#NoSuchView]]'), findsOneWidget);
    });

    testWidgets('tapping a row title calls onOpenNote with the note id', (
      tester,
    ) async {
      String? opened;
      await _pump(
        tester,
        title: 'Projects',
        items: [
          DatabaseSummary.fromJson(_summaryJson(id: 'db1', title: 'Projects')),
        ],
        onOpenNote: (id) => opened = id,
      );

      await tester.tap(find.byKey(const Key('database.embed.row.n1.title')));
      await tester.pumpAndSettle();

      expect(opened, 'n1');
    });

    testWidgets(
      'tapping Show all calls onShowAll with the database id and view name',
      (tester) async {
        String? dbId;
        String? viewName;
        await _pump(
          tester,
          title: 'Projects',
          items: [
            DatabaseSummary.fromJson(
              _summaryJson(id: 'db1', title: 'Projects'),
            ),
          ],
          onShowAll: (id, view) {
            dbId = id;
            viewName = view;
          },
        );

        await tester.tap(find.byKey(const Key('database.embed.showAll')));
        await tester.pumpAndSettle();

        expect(dbId, 'db1');
        expect(viewName, 'All');
      },
    );

    testWidgets('requests only the first 50 rows', (tester) async {
      http.Request? captured;
      await _pump(
        tester,
        title: 'Projects',
        items: [
          DatabaseSummary.fromJson(_summaryJson(id: 'db1', title: 'Projects')),
        ],
        onQuery: (request) {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[],
              'next_cursor': null,
            }),
            200,
          );
        },
      );

      expect(captured, isNotNull);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['limit'], 50);
    });

    testWidgets('a board view groups rows into columns by group_by', (
      tester,
    ) async {
      await _pump(
        tester,
        title: 'Projects',
        items: [
          DatabaseSummary.fromJson(_summaryJson(id: 'db1', title: 'Projects')),
        ],
        onQuery: (request) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                _rowJson(
                  id: 'n1',
                  title: 'Row one',
                  properties: {'status': 'todo'},
                ),
                _rowJson(
                  id: 'n2',
                  title: 'Row two',
                  properties: {'status': 'done'},
                ),
              ],
              'next_cursor': null,
            }),
            200,
          );
        },
      );
    });

    testWidgets(
      'refreshes on a debounced `changed` event with the 1s cadence',
      (tester) async {
        final controller = StreamController<RealtimeEvent>();
        addTearDown(controller.close);
        var queryCount = 0;
        var scheduledDelay = Duration.zero;
        await _pump(
          tester,
          title: 'Projects',
          items: [
            DatabaseSummary.fromJson(
              _summaryJson(id: 'db1', title: 'Projects'),
            ),
          ],
          events: controller.stream,
          debounceScheduler: (d) {
            scheduledDelay = d;
            return Future<void>.value();
          },
          onQuery: (request) {
            queryCount += 1;
            return http.Response(
              jsonEncode(<String, Object?>{
                'items': <Object?>[],
                'next_cursor': null,
              }),
              200,
            );
          },
        );
        expect(queryCount, 1);

        controller.add(
          const RealtimeMessage(
            ChangedEvent(
              noteId: 'n1',
              version: 2,
              by: 'cedric',
              action: ChangeAction.updated,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(scheduledDelay, const Duration(seconds: 1));
        expect(queryCount, 2);
      },
    );
  });
}
