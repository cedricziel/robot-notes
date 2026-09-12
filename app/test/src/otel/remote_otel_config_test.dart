import 'package:app/src/otel/remote_otel_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('fetchRemoteOtelConfig', () {
    test('GETs {baseUrl}/otel-config and parses an enabled response', () async {
      Uri? requestedUri;
      final httpClient = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '{"enabled":true,"endpoint":"https://otel.example.com",'
          '"headers":{"authorization":"Bearer secret","x-tenant-id":"homelab"}}',
          200,
        );
      });

      final config = await fetchRemoteOtelConfig(
        'https://notes.example.com',
        httpClient: httpClient,
      );

      expect(requestedUri, Uri.parse('https://notes.example.com/otel-config'));
      expect(config.endpoint, Uri.parse('https://otel.example.com'));
      expect(config.headers, {
        'authorization': 'Bearer secret',
        'x-tenant-id': 'homelab',
      });
    });

    test(
      'returns a disabled config when the server reports disabled',
      () async {
        final httpClient = MockClient(
          (request) async => http.Response('{"enabled":false}', 200),
        );

        final config = await fetchRemoteOtelConfig(
          'https://notes.example.com',
          httpClient: httpClient,
        );

        expect(config.endpoint, isNull);
        expect(config.headers, isEmpty);
      },
    );

    test('returns a disabled config on a non-200 response', () async {
      final httpClient = MockClient(
        (request) async => http.Response('not found', 404),
      );

      final config = await fetchRemoteOtelConfig(
        'https://notes.example.com',
        httpClient: httpClient,
      );

      expect(config.endpoint, isNull);
    });

    test('returns a disabled config on malformed JSON', () async {
      final httpClient = MockClient(
        (request) async => http.Response('not json', 200),
      );

      final config = await fetchRemoteOtelConfig(
        'https://notes.example.com',
        httpClient: httpClient,
      );

      expect(config.endpoint, isNull);
    });

    test('returns a disabled config when the request throws', () async {
      final httpClient = MockClient((request) async {
        throw const HttpExceptionForTest();
      });

      final config = await fetchRemoteOtelConfig(
        'https://notes.example.com',
        httpClient: httpClient,
      );

      expect(config.endpoint, isNull);
    });

    test('returns a disabled config for a malformed endpoint value', () async {
      final httpClient = MockClient(
        (request) async =>
            http.Response('{"enabled":true,"endpoint":"not-a-url"}', 200),
      );

      final config = await fetchRemoteOtelConfig(
        'https://notes.example.com',
        httpClient: httpClient,
      );

      expect(config.endpoint, isNull);
    });
  });
}

class HttpExceptionForTest implements Exception {
  const HttpExceptionForTest();
}
