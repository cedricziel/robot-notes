import 'dart:convert';

import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  group('SecureConfigStore', () {
    late _Storage storage;
    late Map<String, String> values;
    late SecureConfigStore store;
    setUp(() {
      storage = _Storage();
      values = {};
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((call) async => values[call.namedArguments[#key]]);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((call) async {
        values[call.namedArguments[#key] as String] =
            call.namedArguments[#value] as String;
      });
      when(() => storage.delete(key: any(named: 'key')))
          .thenAnswer((call) async {
            values.remove(call.namedArguments[#key]);
          });
      store = SecureConfigStore(storage: storage);
    });
    const session = AppConfig(
      baseUrl: 'https://notes.example',
      apiKey: 'new-access',
      actor: 'Alice',
      oauthClientId: 'client-1',
      oauthRefreshToken: 'new-refresh',
      oauthRefreshRequestId: 'independent-secret',
      vaultId: 'personal',
    );
    test('saves the credential pair in one secure storage entry', () async {
      await store.write(session);
      expect(values, hasLength(1));
      expect(jsonDecode(values.values.single), session.toJson());
      expect(await store.read(), session);
    });
    test(
      'reads legacy credentials and prefers their saved replacement',
      () async {
        values.addAll({
          'robot_notes.base_url': session.baseUrl,
          'robot_notes.actor': session.actor,
          'robot_notes.api_key': 'old-access',
          'robot_notes.oauth_client_id': 'client-1',
          'robot_notes.oauth_refresh_token': 'old-refresh',
        });
        final migrated = (await store.read())!;
        expect(migrated.apiKey, 'old-access');
        expect(
          migrated.oauthRefreshRequestId,
          matches(RegExp(r'^[a-f0-9]{64}$')),
        );
        expect(
          (await store.read())!.oauthRefreshRequestId,
          migrated.oauthRefreshRequestId,
        );
        await store.write(session);
        expect(await store.read(), session);
        await store.clear();
        expect(await store.read(), isNull);
      },
    );
    test(
      'failed replacement preserves the complete previous session',
      () async {
        await store.write(session);
        when(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((_) async => throw StateError('storage interrupted'));
        await expectLater(
          store.write(
            const AppConfig(
              baseUrl: 'https://notes.example',
              apiKey: 'replacement-access',
              actor: 'Alice',
              oauthClientId: 'client-1',
              oauthRefreshToken: 'replacement-refresh',
            ),
          ),
          throwsStateError,
        );
        expect(await store.read(), session);
      },
    );
  });

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
