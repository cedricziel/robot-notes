import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/search/search_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

http.Response _hitsBody(List<Map<String, Object?>> hits) => http.Response(
      jsonEncode(<String, Object?>{
        'items': hits,
        'limit': 50,
      }),
      200,
    );

void main() {
  group('NotesSearchController', () {
    test('debounces multiple keystrokes into a single GET /search', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _hitsBody(<Map<String, Object?>>[
          <String, Object?>{
            'id': '01H',
            'title': 'hello',
            'snippet': 'hello world',
            'rank': -1.0,
          },
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      // Fake scheduler: completes only when the test signals it. This lets
      // the test stack up multiple setQuery() calls before the debounce
      // window elapses.
      final gates = <Completer<void>>[];
      Completer<void> latestGate() {
        final c = Completer<void>();
        gates.add(c);
        return c;
      }

      final ctrl = NotesSearchController(
        api: api,
        scheduler: (d) => latestGate().future,
      );
      addTearDown(ctrl.dispose);

      ctrl.setQuery('h');
      ctrl.setQuery('he');
      ctrl.setQuery('hel');
      ctrl.setQuery('hello');

      // None of these should have hit the server yet — the scheduler is
      // pending. Now release every gate; only the most recent generation
      // should result in a request.
      for (final g in gates) {
        g.complete();
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(ctrl.value.hits, hasLength(1));
      expect(ctrl.value.hits.first.title, 'hello');
    });

    test('emptying the query clears results without issuing a request',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _hitsBody(<Map<String, Object?>>[
          <String, Object?>{
            'id': '01H',
            'title': 'hello',
            'snippet': 'hi',
            'rank': -1.0,
          },
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesSearchController(
        api: api,
        scheduler: (_) async {},
      );
      addTearDown(ctrl.dispose);

      ctrl.setQuery('hello');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(ctrl.value.hits, hasLength(1));

      ctrl.setQuery('');
      // No further requests should fire.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(ctrl.value.hits, isEmpty);
      expect(ctrl.value.query, '');
    });

    test('debounce respects the configured window', () async {
      final delays = <Duration>[];
      final mock = MockClient((request) async {
        return _hitsBody(<Map<String, Object?>>[]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesSearchController(
        api: api,
        debounce: const Duration(milliseconds: 250),
        scheduler: (d) async {
          delays.add(d);
        },
      );
      addTearDown(ctrl.dispose);

      ctrl.setQuery('hi');
      await Future<void>.delayed(Duration.zero);

      expect(delays.single, const Duration(milliseconds: 250));
    });
  });
}
