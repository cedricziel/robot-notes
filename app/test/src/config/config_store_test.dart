import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryConfigStore', () {
    test('round-trips an AppConfig with OAuth fields', () async {
      final store = InMemoryConfigStore();
      const config = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'access-token',
        actor: 'Alice',
        oauthClientId: 'client-1',
        oauthRefreshToken: 'refresh-1',
      );

      await store.write(config);
      final read = await store.read();

      expect(read, equals(config));
    });

    test('the registered OAuth client id survives clear()', () async {
      final store = InMemoryConfigStore();
      await store.writeRegisteredOAuthClientId(
        'https://notes.example',
        'client-1',
      );
      await store.write(
        const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'k',
          actor: 'Alice',
        ),
      );

      await store.clear();

      expect(await store.read(), isNull);
      expect(
        await store.readRegisteredOAuthClientId('https://notes.example'),
        'client-1',
      );
    });

    test(
      'readRegisteredOAuthClientId is null before anything is written',
      () async {
        final store = InMemoryConfigStore();
        expect(
          await store.readRegisteredOAuthClientId('https://notes.example'),
          isNull,
        );
      },
    );

    test(
      'readRegisteredOAuthClientId is null for a different base URL',
      () async {
        final store = InMemoryConfigStore();
        await store.writeRegisteredOAuthClientId(
          'https://a.example',
          'client-1',
        );
        expect(
          await store.readRegisteredOAuthClientId('https://b.example'),
          isNull,
        );
      },
    );
  });
}
