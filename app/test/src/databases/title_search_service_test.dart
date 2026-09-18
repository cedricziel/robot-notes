import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/title_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example.com',
  apiKey: 'test-key',
  actor: 'cedric',
);

const _now = '2025-01-01T00:00:00.000Z';

void main() {
  group('TitleSearchService', () {
    test('queries GET /search and returns matching titles', () async {
      String? seenQuery;
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/search') {
          seenQuery = request.url.queryParameters['q'];
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                {
                  'id': '02H',
                  'title': 'Project Alpha',
                  'snippet': 's',
                  'rank': 1.0,
                  'updated_at': _now,
                },
                {
                  'id': '03H',
                  'title': 'Project Beta',
                  'snippet': 's',
                  'rank': 0.5,
                  'updated_at': _now,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final service = TitleSearchService(api: api);

      final titles = await service.search('Proj');

      expect(seenQuery, 'Proj');
      expect(titles, ['Project Alpha', 'Project Beta']);
    });

    test('an empty query returns no titles without a request', () async {
      var searchCalls = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/search') searchCalls += 1;
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final service = TitleSearchService(api: api);

      final titles = await service.search('   ');

      expect(titles, isEmpty);
      expect(searchCalls, 0);
    });

    test('a request failure is swallowed and returns no titles', () async {
      final mock = MockClient((request) async {
        return http.Response('boom', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final service = TitleSearchService(api: api);

      final titles = await service.search('Proj');

      expect(titles, isEmpty);
    });

    test('an optional database restriction hook is consulted with the query '
        'and its result is returned instead of GET /search', () async {
      var searchCalls = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/search') searchCalls += 1;
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final service = TitleSearchService(
        api: api,
        databaseRestriction: (query) async => ['Restricted Alpha'],
      );

      final titles = await service.search('Proj');

      expect(titles, ['Restricted Alpha']);
      expect(searchCalls, 0);
    });
  });
}
