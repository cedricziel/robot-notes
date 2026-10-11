import 'dart:async';

import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:app/src/auth/oidc_session_refresher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'repeated resumes recover after a stalled refresh and wake network failure',
    (tester) async {
      final stalled = Completer<http.Response>();
      var refreshes = 0;
      final store = InMemoryConfigStore();
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) {
            refreshes++;
            return switch (refreshes) {
              1 => stalled.future,
              2 => Future.error(http.ClientException('Network unavailable')),
              _ => Future.value(
                http.Response(
                  '{"access_token":"recovered","refresh_token":"rotated"}',
                  200,
                ),
              ),
            };
          }),
        ),
      );
      await tester.pump();
      const config = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'old',
        actor: 'Alice',
        oauthClientId: 'client',
        oauthRefreshToken: 'refresh',
      );
      holder.set(config);
      await tester.pumpWidget(
        MaterialApp(
          home: AppRouterShell(
            configHolder: holder,
            child: const Text('Open draft'),
          ),
        ),
      );
      final workspace = tester.element(find.text('Open draft'));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(refreshes, 1);
      await tester.pump(const Duration(seconds: 31));
      expect(holder.config, config);
      expect(holder.sessionExpired, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(refreshes, 2);
      expect(holder.config, config);
      expect(holder.sessionExpired, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(refreshes, 3);
      expect(holder.config?.apiKey, 'recovered');
      expect((await store.read())?.oauthRefreshToken, 'rotated');
      expect(tester.element(find.text('Open draft')), same(workspace));

      stalled.complete(
        http.Response(
          '{"access_token":"late","refresh_token":"late-refresh"}',
          200,
        ),
      );
      await tester.pump();
      expect(holder.config?.apiKey, 'recovered');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
      holder.dispose();
    },
  );

  testWidgets(
    'renews periodically and on resume without replacing the workspace',
    (tester) async {
      var refreshes = 0;
      final store = InMemoryConfigStore();
      final holder = ConfigHolder(
        store,
        refresher: OidcSessionRefresher(
          clientFactory: () => MockClient((_) async {
            refreshes++;
            return http.Response(
              '{"access_token":"token-$refreshes","refresh_token":"refresh-$refreshes"}',
              200,
            );
          }),
        ),
      );
      await tester.pump();
      holder.set(
        const AppConfig(
          baseUrl: 'https://notes.example',
          apiKey: 'old',
          actor: 'Alice',
          oauthClientId: 'client',
          oauthRefreshToken: 'refresh',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AppRouterShell(
            configHolder: holder,
            child: const Text('Open draft'),
          ),
        ),
      );
      final workspace = tester.element(find.text('Open draft'));
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(holder.config?.apiKey, 'token-1');
      expect((await store.read())?.oauthRefreshToken, 'refresh-1');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(holder.config?.apiKey, 'token-2');
      expect(tester.element(find.text('Open draft')), same(workspace));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
      holder.dispose();
    },
  );

  testWidgets('expired session hides notes and offers sign-in', (tester) async {
    final holder = ConfigHolder.seeded(
      const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'key',
        actor: 'Alice',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppRouterShell(
          configHolder: holder,
          child: const Text('Private notes'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Private notes'), findsOneWidget);
    holder.expireSession();
    await tester.pump();
    expect(find.text('Private notes'), findsNothing);
    expect(find.text('Your session has expired.'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(holder.config, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
    holder.dispose();
  });
}
