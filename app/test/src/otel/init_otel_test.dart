import 'package:app/src/otel/otel_bootstrap.dart';
import 'package:app/src/otel/otel_build_config.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart' as logging;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await OTelSdk.reset();
  });

  group('initOtel', () {
    test('wires a working logging bridge', () async {
      var callCount = 0;
      final httpClient = MockClient((request) async {
        callCount++;
        return http.Response('', 200);
      });

      await initOtel(
        buildConfig: OtelBuildConfig(
          endpoint: Uri.parse('https://otel.example.com'),
        ),
        httpClient: httpClient,
      );
      logging.Logger('app_init_test').info('hello');
      await OTelSdk.instance.forceFlush();

      expect(callCount, greaterThan(0));
    });

    test('re-initializing (hot restart) does not leave the previous SDK '
        'instance receiving further records', () async {
      var firstClientCalls = 0;
      final firstClient = MockClient((request) async {
        firstClientCalls++;
        return http.Response('', 200);
      });
      await initOtel(
        buildConfig: OtelBuildConfig(
          endpoint: Uri.parse('https://first.example.com'),
        ),
        httpClient: firstClient,
      );

      var secondClientCalls = 0;
      final secondClient = MockClient((request) async {
        secondClientCalls++;
        return http.Response('', 200);
      });
      final secondSdk = await initOtel(
        buildConfig: OtelBuildConfig(
          endpoint: Uri.parse('https://second.example.com'),
        ),
        httpClient: secondClient,
      );

      logging.Logger('app_init_test').info('after re-init');
      await secondSdk.forceFlush();

      expect(secondClientCalls, greaterThan(0));
      expect(firstClientCalls, 0);
      expect(OTelSdk.instance, same(secondSdk));
    });
  });
}
