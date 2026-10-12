import 'dart:async';

import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/auth/oidc_session_refresher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

const initial = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'secret',
  actor: 'tester',
);

class DelayedStore extends InMemoryConfigStore {
  final started = Completer<void>();
  final release = Completer<void>();
  bool fail = false;
  @override
  Future<void> write(AppConfig config) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('storage unavailable');
    await super.write(config);
  }
}

void main() {
  test(
    'vault switch preserves configuration when departure is declined',
    () async {
      final holder = ConfigHolder.seeded(
        const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'key',
          actor: 'tester',
        ),
      );
      addTearDown(holder.dispose);
      final owner = Object();
      holder.navigation.register(
        owner,
        Uri.parse('/notes/A'),
        () async => false,
      );
      final originalKey = holder.sessionKey;
      expect(await holder.selectVault('work'), isFalse);
      expect(holder.config!.vaultId, 'default');
      expect(holder.sessionKey, originalKey);
    },
  );

  const oauth = AppConfig(
    baseUrl: 'https://notes.example',
    apiKey: 'old',
    actor: 'Alice',
    oauthClientId: 'client',
    oauthRefreshToken: 'refresh',
  );

  test(
    'concurrent rejections rotate once and persist the new session',
    () async {
      final store = InMemoryConfigStore();
      var refreshes = 0;
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) async {
            refreshes++;
            return http.Response(
              '{"access_token":"new","refresh_token":"rotated"}',
              200,
            );
          }),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(oauth);
      final results = await Future.wait([
        holder.renewSession('old'),
        holder.renewSession('old'),
      ]);
      expect(results.map((value) => value?.apiKey), ['new', 'new']);
      expect(refreshes, 1);
      expect((await store.read())?.oauthRefreshToken, 'rotated');
      expect((await holder.renewSession('old'))?.apiKey, 'new');
      expect(refreshes, 1);
    },
  );

  test(
    'temporary startup refresh failure preserves the saved session',
    () async {
      final store = InMemoryConfigStore();
      await store.write(oauth);
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) async => http.Response('', 503)),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(holder.loaded, isTrue);
      expect(holder.config, oauth);
      expect(holder.sessionExpired, isFalse);
      expect(await store.read(), oauth);
    },
  );

  test('starting offline preserves credentials and finishes loading', () async {
    final store = InMemoryConfigStore();
    await store.write(oauth);
    final holder = ConfigHolder(
      store,
      refresher: OidcSessionRefresher(
        clientFactory: () =>
            MockClient((_) async => throw http.ClientException('offline')),
      ),
    );
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(holder.loaded, isTrue);
    expect(holder.config, oauth);
    expect(await store.read(), oauth);
  });

  test('rejected refresh marks the session expired', () async {
    final holder = ConfigHolder(
      InMemoryConfigStore(),
      refresher: OidcSessionRefresher(
        clientFactory: () => MockClient(
          (_) async => http.Response('{"error":"invalid_grant"}', 400),
        ),
      ),
    );
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    holder.set(oauth);
    expect(await holder.renewSession('old'), isNull);
    expect(holder.sessionExpired, isTrue);
  });

  test(
    'temporary refresh failures preserve credentials for a later retry',
    () async {
      final holder = ConfigHolder(
        InMemoryConfigStore(),
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) async => http.Response('', 503)),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(oauth);
      await expectLater(
        holder.renewSession('old'),
        throwsA(isA<OidcRefreshException>()),
      );
      expect(holder.sessionExpired, isFalse);
      expect(holder.config, oauth);
    },
  );

  test(
    'logout clears credentials without waiting for a stalled refresh',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final store = InMemoryConfigStore();
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) {
            started.complete();
            return response.future;
          }),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      await store.write(oauth);
      holder.set(oauth);
      final refresh = holder.renewSession('old');
      await started.future;
      final logout = holder.reset();
      expect(holder.config, isNull);
      await logout;
      expect(await store.read(), isNull);
      expect(response.isCompleted, isFalse);
      response.complete(
        http.Response('{"access_token":"new","refresh_token":"rotated"}', 200),
      );
      expect(await refresh, isNull);
      await logout;
      expect(holder.config, isNull);
      expect(await store.read(), isNull);
    },
  );

  test(
    'vault switching completes while refresh is stalled and survives rotation',
    () async {
      final response = Completer<http.Response>();
      final store = InMemoryConfigStore();
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) => response.future),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(oauth);
      final refresh = holder.renewSession('old');
      final selection = holder.selectVault('work');
      await Future<void>.delayed(Duration.zero);
      expect(holder.config?.vaultId, 'work');
      expect(response.isCompleted, isFalse);
      expect(await selection, isTrue);
      response.complete(
        http.Response('{"access_token":"new","refresh_token":"rotated"}', 200),
      );
      expect((await refresh)?.vaultId, 'work');
      expect((await store.read())?.vaultId, 'work');
      expect(holder.config?.apiKey, 'new');
    },
  );

  test(
    'a new sign-in can renew while an old session refresh is stalled',
    () async {
      final oldResponse = Completer<http.Response>();
      final store = InMemoryConfigStore();
      var requests = 0;
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) {
            requests++;
            return requests == 1
                ? oldResponse.future
                : Future.value(
                    http.Response(
                      '{"access_token":"new-session","refresh_token":"new-refresh"}',
                      200,
                    ),
                  );
          }),
        ),
      );
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(oauth);
      final oldRefresh = holder.renewSession('old');
      await holder.reset();
      holder.set(oauth);
      final newRefresh = holder.renewSession('old');
      await Future<void>.delayed(Duration.zero);
      expect(holder.config?.apiKey, 'new-session');
      expect(oldResponse.isCompleted, isFalse);
      expect((await newRefresh)?.apiKey, 'new-session');
      oldResponse.complete(
        http.Response(
          '{"access_token":"stale","refresh_token":"stale-refresh"}',
          200,
        ),
      );
      expect(await oldRefresh, isNull);
      expect((await store.read())?.apiKey, 'new-session');
    },
  );

  test('logout waits for vault persistence and clears credentials', () async {
    final store = DelayedStore();
    final holder = ConfigHolder(store);
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    holder.set(initial);
    final selection = holder.selectVault('work');
    await store.started.future;
    final logout = holder.reset();
    store.release.complete();
    expect(await selection, isFalse);
    await logout;
    expect(holder.config, isNull);
    expect(await store.read(), isNull);
  });

  test(
    'failed persistence leaves selection unchanged and queue usable',
    () async {
      final store = DelayedStore()..fail = true;
      final holder = ConfigHolder(store);
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(initial);
      store.release.complete();
      await expectLater(holder.selectVault('work'), throwsStateError);
      expect(holder.config, initial);
      await holder.reset();
      expect(await store.read(), isNull);
    },
  );

  test('rapid selections persist the last selection consistently', () async {
    final store = DelayedStore();
    final holder = ConfigHolder(store);
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    holder.set(initial);
    final first = holder.selectVault('work');
    final second = holder.selectVault('personal');
    store.release.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(holder.config?.vaultId, 'personal');
    expect(await store.read(), holder.config);
  });
}
