import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/src/config.dart';
import 'package:server/src/otel/otel_bootstrap.dart';
import 'package:test/test.dart';

void main() {
  group('createOtelLoggerProvider', () {
    test('with no otlpEndpoint configured, never makes an HTTP call', () async {
      var callCount = 0;
      final httpClient = MockClient((request) async {
        callCount++;
        return http.Response('', 200);
      });
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );

      final provider = createOtelLoggerProvider(config, httpClient: httpClient);
      provider.getLogger(name: 'test').info('should be dropped');
      await provider.forceFlush();

      expect(callCount, 0);
    });

    test('with otlpEndpoint configured, POSTs the record to /v1/logs',
        () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      Map<String, Object?>? capturedBody;
      final httpClient = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        capturedBody = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response('', 200);
      });
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--otel-endpoint',
          'https://otel.example.com',
          '--otel-headers',
          'X-Api-Key=secret',
        ],
        env: const {},
      );

      final provider = createOtelLoggerProvider(config, httpClient: httpClient);
      provider.getLogger(name: 'test').info('hello');
      await provider.forceFlush();

      expect(capturedUri, Uri.parse('https://otel.example.com/v1/logs'));
      expect(capturedHeaders?['X-Api-Key'], 'secret');
      expect(capturedBody, isNotNull);
    });
  });
}
