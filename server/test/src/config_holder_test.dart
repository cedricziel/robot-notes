import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart';
import 'package:test/test.dart';

const _baseConfig = Config(
  apiKey: 'rn_holder_key',
  dataDir: './data',
  port: 8080,
  lockTtlSeconds: 60,
);

void main() {
  setUp(debugResetConfig);
  tearDown(debugResetConfig);

  group('config_holder', () {
    test('config getter throws StateError before setConfig is called', () {
      expect(() => config, throwsStateError);
    });

    test('config getter returns the value installed by setConfig', () {
      setConfig(_baseConfig);
      expect(identical(config, _baseConfig), isTrue);
    });

    test('setConfig is idempotent for the same instance', () {
      setConfig(_baseConfig);
      expect(() => setConfig(_baseConfig), returnsNormally);
      expect(identical(config, _baseConfig), isTrue);
    });

    test('setConfig throws when called with a different instance', () {
      setConfig(_baseConfig);
      const other = Config(
        apiKey: 'rn_other_key',
        dataDir: './data',
        port: 8080,
        lockTtlSeconds: 60,
      );
      expect(() => setConfig(other), throwsStateError);
    });

    test('debugResetConfig clears the holder', () {
      setConfig(_baseConfig);
      debugResetConfig();
      expect(() => config, throwsStateError);
    });
  });
}
