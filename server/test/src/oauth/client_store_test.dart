import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-client-store-test-');

ClientStore _store(Directory tmp, {Clock? clock, Random? random}) {
  return ClientStore(
    dir: Directory('${tmp.path}/clients'),
    clock: clock ?? FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    random: random,
  );
}

void main() {
  late Directory tmp;

  setUp(() => tmp = _tempDir());
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('ClientStore.register', () {
    test('persists a JSON file keyed by client_id', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Desk Assistant',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
      );

      final file = File(
        '${tmp.path}/clients/${registered.client.clientId}.json',
      );
      expect(file.existsSync(), isTrue);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(json['client_id'], registered.client.clientId);
      expect(json['client_name'], 'Desk Assistant');
    });

    test('a confidential client secret is stored hashed, not raw', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Confidential Client',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      expect(registered.clientSecret, isNotNull);
      final file = File(
        '${tmp.path}/clients/${registered.client.clientId}.json',
      );
      final raw = await file.readAsString();
      expect(raw.contains(registered.clientSecret!), isFalse);
      expect(registered.client.clientSecretHash, isNotNull);
      expect(
        registered.client.clientSecretHash,
        isNot(registered.clientSecret),
      );
    });

    test('a public client has no client secret', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Public Client',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      expect(registered.clientSecret, isNull);
      expect(registered.client.clientSecretHash, isNull);
    });
  });

  group('ClientStore.get', () {
    test('round-trips a registered client', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Desk Assistant',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      final fetched = await store.get(registered.client.clientId);
      expect(fetched, isNotNull);
      expect(fetched!.clientId, registered.client.clientId);
      expect(fetched.clientName, 'Desk Assistant');
      expect(fetched.redirectUris, ['https://agent.example/callback']);
    });

    test('returns null for an unknown client id', () async {
      final store = _store(tmp);
      expect(await store.get('does-not-exist'), isNull);
    });

    test('skips a malformed file and logs a warning', () async {
      final logs = <LogRecord>[];
      final store = ClientStore(
        dir: Directory('${tmp.path}/clients'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        logger: Logger.detached('test')..onRecord.listen(logs.add),
      );
      final dir = Directory('${tmp.path}/clients')..createSync(recursive: true);
      File('${dir.path}/broken.json').writeAsStringSync('not json');

      expect(await store.get('broken'), isNull);
      expect(logs, isNotEmpty);
      expect(logs.single.level, Level.WARNING);
    });
  });

  group('ClientStore.verifySecret', () {
    test('accepts the right secret', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Confidential Client',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      expect(
        store.verifySecret(registered.client, registered.clientSecret!),
        isTrue,
      );
    });

    test('rejects a wrong secret', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Confidential Client',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      expect(store.verifySecret(registered.client, 'wrong-secret'), isFalse);
    });

    test('rejects any secret for a public client', () async {
      final store = _store(tmp);
      final registered = await store.register(
        clientName: 'Public Client',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      );

      expect(store.verifySecret(registered.client, 'anything'), isFalse);
    });
  });
}
