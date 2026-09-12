import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/config.dart';
import 'package:test/test.dart';

import '../../routes/otel-config.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({required HttpMethod method, required Config config}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(config);
  return ctx;
}

Config _config({
  Uri? otlpEndpoint,
  Map<String, String> otlpHeaders = const {},
}) {
  return Config(
    apiKey: 'test-key',
    dataDir: './data',
    port: 8080,
    lockTtlSeconds: 60,
    otlpEndpoint: otlpEndpoint,
    otlpHeaders: otlpHeaders,
  );
}

void main() {
  group('GET /otel-config', () {
    test('reports disabled when no OTLP endpoint is configured', () async {
      final response = route.onRequest(
        _ctx(method: HttpMethod.get, config: _config()),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.json(), {'enabled': false});
    });

    test('reports the configured endpoint and headers when set', () async {
      final response = route.onRequest(
        _ctx(
          method: HttpMethod.get,
          config: _config(
            otlpEndpoint: Uri.parse('https://o11y-ingest.example.com'),
            otlpHeaders: const {
              'authorization': 'Bearer secret',
              'x-tenant-id': 'homelab',
            },
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.json(), {
        'enabled': true,
        'endpoint': 'https://o11y-ingest.example.com',
        'headers': {'authorization': 'Bearer secret', 'x-tenant-id': 'homelab'},
      });
    });

    test('response is never cached', () async {
      final response = route.onRequest(
        _ctx(method: HttpMethod.get, config: _config()),
      );
      expect(response.headers['cache-control'], 'no-store');
    });
  });

  group('non-GET /otel-config', () {
    test('POST returns 405 with method_not_allowed', () async {
      final response = route.onRequest(
        _ctx(method: HttpMethod.post, config: _config()),
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
      expect(await response.json(), {'error': 'method_not_allowed'});
    });
  });
}
