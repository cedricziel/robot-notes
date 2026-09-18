import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
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

Map<String, Object?> _summaryJson({
  required String id,
  required String title,
  String path = '',
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': path,
  'source': <String, Object?>{'folder': path, 'include_subfolders': true},
  'row_count': 0,
};

Map<String, Object?> _definitionJson({
  required String id,
  required String title,
  int version = 1,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': '',
  'version': version,
  'source': <String, Object?>{'folder': '', 'include_subfolders': true},
  'properties': <String, Object?>{},
  'views': <Object?>[
    <String, Object?>{'name': 'All', 'type': 'table'},
  ],
  'created_at': _now,
  'updated_at': _now,
};

void main() {
  group('DatabasesController', () {
    test('refresh fetches the list', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/databases');
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              _summaryJson(id: '01A', title: 'Projects'),
              _summaryJson(id: '01B', title: 'Reading'),
            ],
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabasesController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.value.items.map((d) => d.title), ['Projects', 'Reading']);
      expect(ctrl.value.isLoading, isFalse);
      expect(ctrl.value.error, isNull);
    });

    test('a refresh failure surfaces as an error', () async {
      final mock = MockClient((request) async => http.Response('boom', 500));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabasesController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.value.error, isNotNull);
      expect(ctrl.value.isLoading, isFalse);
    });

    test('definition() fetches once and caches the result', () async {
      var gets = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/databases/01A') {
          gets += 1;
          return http.Response(
            jsonEncode(_definitionJson(id: '01A', title: 'Projects')),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabasesController(api: api);
      addTearDown(ctrl.dispose);

      final first = await ctrl.definition('01A');
      final second = await ctrl.definition('01A');

      expect(gets, 1);
      expect(first.title, 'Projects');
      expect(identical(first, second), isTrue);
      expect(ctrl.cachedDefinition('01A'), same(first));
    });

    test('resolveByTitle matches case-insensitively', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_summaryJson(id: '01A', title: 'Projects')],
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabasesController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.resolveByTitle('projects')?.id, '01A');
      expect(ctrl.resolveByTitle('PROJECTS')?.id, '01A');
      expect(ctrl.resolveByTitle('nope'), isNull);
    });

    test('resolveByTitle NFC-normalizes before comparing', () async {
      // "Café" spelled with a combining acute accent (NFD) vs. the
      // precomposed "é" (NFC) the server sent back.
      const nfc = 'Café';
      const nfd = 'Cafe\u0301';
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_summaryJson(id: '01A', title: nfc)],
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = DatabasesController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.resolveByTitle(nfd)?.id, '01A');
    });

    test('a changed event debounces to at most one refresh per second and '
        'invalidates the definition cache', () async {
      var listGets = 0;
      var defGets = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/databases') {
          listGets += 1;
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[_summaryJson(id: '01A', title: 'Projects')],
            }),
            200,
          );
        }
        if (request.url.path == '/databases/01A') {
          defGets += 1;
          return http.Response(
            jsonEncode(_definitionJson(id: '01A', title: 'Projects')),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>();
      final scheduledDelays = <Duration>[];
      final gates = <Completer<void>>[];
      final ctrl = DatabasesController(
        api: api,
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

      await ctrl.definition('01A');
      expect(defGets, 1);

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01A',
            version: 2,
            by: 'agent',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      // A second event arriving before the debounce elapses coalesces
      // into the same pending refresh, not a second one.
      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01A',
            version: 3,
            by: 'agent',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(scheduledDelays, [
        const Duration(seconds: 1),
        const Duration(seconds: 1),
      ]);
      expect(listGets, 0);

      // The first (superseded) debounce firing must not trigger a
      // refresh; only the latest one does.
      gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(listGets, 0);

      gates.last.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(listGets, 1);
      // Cache invalidated: fetching the definition again re-fetches.
      await ctrl.definition('01A');
      expect(defGets, 2);
    });
  });
}
