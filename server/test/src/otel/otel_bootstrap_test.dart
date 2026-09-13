import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/src/config.dart';
import 'package:server/src/otel/otel_bootstrap.dart';
import 'package:test/test.dart';

/// Flattens an OTLP-JSON `resource.attributes` array (`[{key, value:
/// {stringValue}}, ...]`) into a plain `{key: stringValue}` map for easy
/// assertions.
Map<String, Object?> _resourceAttributes(Map<String, Object?> body) {
  final resourceSpansOrLogs =
      (body['resourceLogs'] ?? body['resourceSpans'])! as List<dynamic>;
  final resource = (resourceSpansOrLogs.single
      as Map<String, Object?>)['resource']! as Map<String, Object?>;
  final attributes =
      (resource['attributes']! as List<dynamic>).cast<Map<String, Object?>>();
  return {
    for (final attr in attributes)
      attr['key']! as String:
          (attr['value']! as Map<String, Object?>)['stringValue'],
  };
}

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

    test(
      'exports service.namespace and deployment.environment.name on the '
      'resource',
      () async {
        Map<String, Object?>? capturedBody;
        final httpClient = MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response('', 200);
        });
        final config = Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--otel-endpoint',
            'https://otel.example.com',
            '--otel-environment-name',
            'staging',
          ],
          env: const {},
        );

        final provider = createOtelLoggerProvider(
          config,
          httpClient: httpClient,
        );
        provider.getLogger(name: 'test').info('hello');
        await provider.forceFlush();

        final attributes = _resourceAttributes(capturedBody!);
        expect(attributes['service.namespace'], 'robot-notes');
        expect(attributes['deployment.environment.name'], 'staging');
      },
    );
  });

  group('createOtelTracerProvider', () {
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

      final provider = createOtelTracerProvider(config, httpClient: httpClient);
      provider.getTracer(name: 'test').startSpan('span').end();
      await provider.forceFlush();

      expect(callCount, 0);
    });

    test('with otlpEndpoint configured, POSTs the span to /v1/traces',
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

      final provider = createOtelTracerProvider(config, httpClient: httpClient);
      provider.getTracer(name: 'test').startSpan('span').end();
      await provider.forceFlush();

      expect(capturedUri, Uri.parse('https://otel.example.com/v1/traces'));
      expect(capturedHeaders?['X-Api-Key'], 'secret');
      expect(capturedBody, isNotNull);
    });

    test(
      'exports service.namespace and deployment.environment.name on the '
      'resource',
      () async {
        Map<String, Object?>? capturedBody;
        final httpClient = MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response('', 200);
        });
        final config = Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--otel-endpoint',
            'https://otel.example.com',
            '--otel-environment-name',
            'staging',
          ],
          env: const {},
        );

        final provider = createOtelTracerProvider(
          config,
          httpClient: httpClient,
        );
        provider.getTracer(name: 'test').startSpan('span').end();
        await provider.forceFlush();

        final attributes = _resourceAttributes(capturedBody!);
        expect(attributes['service.namespace'], 'robot-notes');
        expect(attributes['deployment.environment.name'], 'staging');
      },
    );
  });
}
