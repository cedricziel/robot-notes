import 'package:app/src/otel/deployment_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deploymentEnvironmentName', () {
    test('is "development" for a debug build regardless of native', () async {
      final result = await deploymentEnvironmentName(
        releaseMode: false,
        distributionEnvironment: () async => 'production',
      );

      expect(result, 'development');
    });

    test(
      'is "testflight" for a release build when native reports testflight',
      () async {
        final result = await deploymentEnvironmentName(
          releaseMode: true,
          distributionEnvironment: () async => 'testflight',
        );

        expect(result, 'testflight');
      },
    );

    test(
      'is "production" for a release build when native reports production',
      () async {
        final result = await deploymentEnvironmentName(
          releaseMode: true,
          distributionEnvironment: () async => 'production',
        );

        expect(result, 'production');
      },
    );

    test('is "production" (not "unknown") for a release build when native '
        'can\'t tell (no plugin, or an indeterminate receipt)', () async {
      final result = await deploymentEnvironmentName(
        releaseMode: true,
        distributionEnvironment: () async => 'unknown',
      );

      expect(result, 'production');
    });
  });
}
