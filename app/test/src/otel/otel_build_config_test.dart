import 'package:app/src/otel/otel_build_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OtelBuildConfig.parse', () {
    test(
      'endpoint is null and headers empty when both raw values are empty',
      () {
        final config = OtelBuildConfig.parse(rawEndpoint: '', rawHeaders: '');
        expect(config.endpoint, isNull);
        expect(config.headers, isEmpty);
      },
    );

    test('parses a valid endpoint', () {
      final config = OtelBuildConfig.parse(
        rawEndpoint: 'https://otel.example.com',
        rawHeaders: '',
      );
      expect(config.endpoint, Uri.parse('https://otel.example.com'));
    });

    test('throws FormatException for a non-http(s) endpoint', () {
      expect(
        () => OtelBuildConfig.parse(
          rawEndpoint: 'ftp://otel.example.com',
          rawHeaders: '',
        ),
        throwsFormatException,
      );
    });

    test('parses comma-separated key=value header pairs', () {
      final config = OtelBuildConfig.parse(
        rawEndpoint: '',
        rawHeaders: 'Authorization=Bearer abc,X-Tenant=homelab',
      );
      expect(config.headers, {
        'Authorization': 'Bearer abc',
        'X-Tenant': 'homelab',
      });
    });

    test('throws FormatException for a header entry missing "="', () {
      expect(
        () => OtelBuildConfig.parse(rawEndpoint: '', rawHeaders: 'not-a-pair'),
        throwsFormatException,
      );
    });
  });
}
