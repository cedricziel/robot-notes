import 'dart:convert';

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
}
