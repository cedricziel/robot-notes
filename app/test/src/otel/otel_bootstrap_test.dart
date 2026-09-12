import 'dart:convert';

import 'package:app/src/config/app_config.dart';
import 'package:app/src/otel/otel_bootstrap.dart';
import 'package:app/src/otel/otel_build_config.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await OTelSdk.reset();
  });

  group('bootstrapOtel', () {
    test('with no endpoint configured, never makes an HTTP call', () async {
      var callCount = 0;
      final httpClient = MockClient((request) async {
        callCount++;
        return http.Response('', 200);
      });

      final sdk = await bootstrapOtel(
        buildConfig: const OtelBuildConfig(),
        httpClient: httpClient,
      );
      sdk.getLogger().info('should be dropped');
      await sdk.forceFlush();

      expect(callCount, 0);
    });

    test('with an endpoint configured, POSTs the record to /v1/logs', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      Map<String, Object?>? capturedBody;
      final httpClient = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        capturedBody = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response('', 200);
      });

      final sdk = await bootstrapOtel(
        buildConfig: OtelBuildConfig(
          endpoint: Uri.parse('https://otel.example.com'),
          headers: const {'X-Api-Key': 'secret'},
        ),
        httpClient: httpClient,
      );
      sdk.getLogger().info('hello');
      await sdk.forceFlush();

      expect(capturedUri, Uri.parse('https://otel.example.com/v1/logs'));
      expect(capturedHeaders?['X-Api-Key'], 'secret');
      expect(capturedBody, isNotNull);
    });
  });

  group('syncOtelWithConfig', () {
    test(
      'with no AppConfig, initializes disabled without any HTTP call',
      () async {
        var callCount = 0;
        final httpClient = MockClient((request) async {
          callCount++;
          return http.Response('', 200);
        });

        final sdk = await syncOtelWithConfig(null, httpClient: httpClient);
        sdk.getLogger().info('should be dropped');
        await sdk.forceFlush();

        expect(callCount, 0);
      },
    );

    test(
      'with an AppConfig, fetches {baseUrl}/otel-config and applies it',
      () async {
        final requestedUris = <Uri>[];
        final httpClient = MockClient((request) async {
          requestedUris.add(request.url);
          if (request.url.path == '/otel-config') {
            return http.Response(
              '{"enabled":true,"endpoint":"https://otel.example.com",'
              '"headers":{"authorization":"Bearer secret"}}',
              200,
            );
          }
          return http.Response('', 200);
        });

        final sdk = await syncOtelWithConfig(
          const AppConfig(
            baseUrl: 'https://notes.example.com',
            apiKey: 'key',
            actor: 'tester',
          ),
          httpClient: httpClient,
        );
        sdk.getLogger().info('hello');
        await sdk.forceFlush();

        expect(
          requestedUris,
          contains(Uri.parse('https://notes.example.com/otel-config')),
        );
        expect(
          requestedUris,
          contains(Uri.parse('https://otel.example.com/v1/logs')),
        );
      },
    );
  });
}
