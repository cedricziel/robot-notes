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

  test('logout during refresh cannot restore credentials', () async {
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
    holder.set(oauth);
    final refresh = holder.renewSession('old');
    await started.future;
    final logout = holder.reset();
    response.complete(
      http.Response('{"access_token":"new","refresh_token":"rotated"}', 200),
    );
    expect(await refresh, isNull);
    await logout;
    expect(holder.config, isNull);
    expect(await store.read(), isNull);
  });

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
