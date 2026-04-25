import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_controller.dart';
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

Map<String, Object?> _metaJson({
  required String id,
  String title = 'note',
  int version = 1,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'version': version,
      'created_at': _now,
      'updated_at': _now,
    };

Map<String, Object?> _noteJson({
  required String id,
  String title = 'note',
  String content = 'body',
  int version = 1,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'content': content,
      'version': version,
      'created_at': _now,
      'updated_at': _now,
    };

void main() {
  group('NotesListController', () {
    test('refresh fetches the first page and exposes items', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/notes');
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              _metaJson(id: '01H', title: 'first'),
              _metaJson(id: '02H', title: 'second'),
            ],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.value.items.map((n) => n.id), <String>['01H', '02H']);
      expect(ctrl.value.isLoadingFirst, isFalse);
      expect(ctrl.value.nextCursor, isNull);
      expect(ctrl.value.error, isNull);
    });

    test('refresh called twice (pull-to-refresh) re-fetches', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_metaJson(id: '01H', title: 'fresh-$calls')],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      await ctrl.refresh();

      expect(calls, 2);
      expect(ctrl.value.items.single.title, 'fresh-2');
    });

    test('loadMore forwards the cursor and appends', () async {
      final cursors = <String?>[];
      final mock = MockClient((request) async {
        cursors.add(request.url.queryParameters['after']);
        if (request.url.queryParameters['after'] == null) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[_metaJson(id: '01H')],
              'limit': 50,
              'next_cursor': '01H',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_metaJson(id: '02H')],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      expect(ctrl.value.hasMore, isTrue);
      await ctrl.loadMore();

      expect(cursors, <String?>[null, '01H']);
      expect(ctrl.value.items.map((n) => n.id), <String>['01H', '02H']);
      expect(ctrl.value.hasMore, isFalse);
    });

    test('loadMore is a no-op when no cursor is available', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_metaJson(id: '01H')],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesListController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      await ctrl.loadMore();
      await ctrl.loadMore();

      expect(calls, 1);
    });

    test('changed{updated} replaces entry in place without manual refresh',
        () async {
      var listCalls = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/notes' && request.method == 'GET') {
          listCalls += 1;
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[_metaJson(id: '01H', version: 1)],
              'limit': 50,
              'next_cursor': null,
            }),
            200,
          );
        }
        if (request.url.path == '/notes/01H' && request.method == 'GET') {
          return http.Response(
            jsonEncode(_noteJson(id: '01H', title: 'edited', version: 7)),
            200,
          );
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final ctrl = NotesListController(api: api, events: events.stream);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      expect(ctrl.value.items.single.version, 1);

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01H',
            version: 7,
            by: 'alice',
            action: ChangeAction.updated,
          ),
        ),
      );
      // Let the stream subscription + the controller's getNote complete.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(listCalls, 1, reason: 'no manual list refresh should have run');
      expect(ctrl.value.items, hasLength(1));
      expect(ctrl.value.items.single.version, 7);
      expect(ctrl.value.items.single.title, 'edited');
    });

    test('changed{created} prepends the new entry', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/notes' && request.method == 'GET') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[_metaJson(id: '01H', title: 'old')],
              'limit': 50,
              'next_cursor': null,
            }),
            200,
          );
        }
        if (request.url.path == '/notes/02H' && request.method == 'GET') {
          return http.Response(
            jsonEncode(_noteJson(id: '02H', title: 'new')),
            200,
          );
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final ctrl = NotesListController(api: api, events: events.stream);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '02H',
            version: 1,
            by: 'alice',
            action: ChangeAction.created,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.items.map((n) => n.id), <String>['02H', '01H']);
    });

    test('changed{deleted} removes the entry', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/notes' && request.method == 'GET') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                _metaJson(id: '01H'),
                _metaJson(id: '02H'),
              ],
              'limit': 50,
              'next_cursor': null,
            }),
            200,
          );
        }
        return http.Response('unexpected: ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final ctrl = NotesListController(api: api, events: events.stream);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01H',
            version: 2,
            by: 'alice',
            action: ChangeAction.deleted,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.items.map((n) => n.id), <String>['02H']);
    });
  });
}
