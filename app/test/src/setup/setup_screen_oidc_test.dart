import 'dart:async';
import 'dart:convert';

import 'package:app/src/auth/oidc_sign_in_controller.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:app/src/setup/setup_controller.dart';
import 'package:app/src/setup/setup_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  // Deterministic across the test host: pin to a desktop or mobile
  // platform for the duration of [body] so the sign-in-option visibility
  // check is exercised the same way regardless of what machine runs the
  // suite. The reset MUST happen before the test callback returns —
  // flutter_test's binding-invariant check runs immediately after, well
  // before any `tearDown`/`addTearDown` callback would fire.
  Future<void> withPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  http.Client oidcSupportedClient() => MockClient((request) async {
    if (request.url.path == '/.well-known/oauth-authorization-server') {
      return http.Response(
        jsonEncode({'robotnotes_oidc_login_supported': true}),
        200,
      );
    }
    return http.Response('not found', 404);
  });

  http.Client oidcUnsupportedClient() =>
      MockClient((request) async => http.Response(jsonEncode({}), 200));

  SetupController setupController(http.Client client) => SetupController(
    store: InMemoryConfigStore(),
    clientFactory: () => client,
  );

  testWidgets('shows a Sign in option once the entered server advertises OIDC '
      'support', (tester) async {
    await withPlatform(TargetPlatform.macOS, () async {
      final store = InMemoryConfigStore();
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(oidcSupportedClient()),
            onConfigured: (_) {},
            oidcController: OidcSignInController(
              store: store,
              launchUri: (uri) async {},
            ),
            capabilitiesClientFactory: oidcSupportedClient,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('setup.continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('setup.signInWithOidc')), findsOneWidget);
    });
  });

  testWidgets('shows no Sign in option when the server does not advertise '
      'support', (tester) async {
    await withPlatform(TargetPlatform.macOS, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(oidcUnsupportedClient()),
            onConfigured: (_) {},
            oidcController: OidcSignInController(
              store: InMemoryConfigStore(),
              launchUri: (uri) async {},
            ),
            capabilitiesClientFactory: oidcUnsupportedClient,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('setup.continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('setup.signInWithOidc')), findsNothing);
    });
  });

  testWidgets(
    "a slower capabilities response for a server the user has since typed "
    "past does not clobber the current server's",
    (tester) async {
      await withPlatform(TargetPlatform.macOS, () async {
        // Keyed by host: /healthz answers immediately (irrelevant to this
        // race), but each well-known request is held until the test
        // explicitly completes it, so the two servers' responses can be
        // resolved in a controlled, out-of-order sequence.
        final pending = <String, Completer<http.Response>>{};
        final client = MockClient((request) async {
          if (request.url.path == '/healthz') {
            return http.Response('', 200);
          }
          final completer = Completer<http.Response>();
          pending[request.url.host] = completer;
          return completer.future;
        });

        await tester.pumpWidget(
          MaterialApp(
            home: SetupScreen(
              controller: setupController(client),
              onConfigured: (_) {},
              oidcController: OidcSignInController(
                store: InMemoryConfigStore(),
                launchUri: (uri) async {},
              ),
              capabilitiesClientFactory: () => client,
            ),
          ),
        );

        await tester.enterText(
          find.byKey(const Key('setup.baseUrl')),
          'https://a.example',
        );
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(pending.containsKey('a.example'), isTrue);

        // The user changes their mind before a.example answers — its
        // request is still in flight underneath.
        await tester.enterText(
          find.byKey(const Key('setup.baseUrl')),
          'https://b.example',
        );
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(pending.containsKey('b.example'), isTrue);

        // b.example (the current server) answers first: unsupported.
        pending['b.example']!.complete(http.Response(jsonEncode({}), 200));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byKey(const Key('setup.continue')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('setup.signInWithOidc')), findsNothing);

        // a.example's stale response now arrives late, claiming support —
        // it must not override b.example's already-applied result.
        pending['a.example']!.complete(
          http.Response(
            jsonEncode({'robotnotes_oidc_login_supported': true}),
            200,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('setup.signInWithOidc')), findsNothing);
      });
    },
  );

  testWidgets('shows a Sign in option on a mobile platform when supported '
      '(via the browser-sheet flow)', (tester) async {
    await withPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(oidcSupportedClient()),
            onConfigured: (_) {},
            oidcController: OidcSignInController(
              store: InMemoryConfigStore(),
              launchUri: (uri) async {},
            ),
            capabilitiesClientFactory: oidcSupportedClient,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('setup.continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('setup.signInWithOidc')), findsOneWidget);
    });
  });

  testWidgets('tapping Sign in drives the controller and completing it '
      'calls onConfigured', (tester) async {
    await withPlatform(TargetPlatform.macOS, () async {
      final store = InMemoryConfigStore();
      const signedInConfig = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'access-token',
        actor: 'Alice Example',
        oauthClientId: 'client-1',
        oauthRefreshToken: 'refresh-1',
      );

      // A fake controller whose signInDesktop just flips straight to
      // success — the real flow's mechanics are covered in
      // oidc_sign_in_controller_test.dart; this test is about
      // SetupScreen reacting to the controller's state, not re-deriving
      // that flow.
      final oidcController = _FakeOidcSignInController(store: store);

      AppConfig? configured;
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(oidcSupportedClient()),
            onConfigured: (c) => configured = c,
            oidcController: oidcController,
            capabilitiesClientFactory: oidcSupportedClient,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('setup.continue')));
      await tester.pumpAndSettle();

      oidcController.nextResult = signedInConfig;
      await tester.tap(find.byKey(const Key('setup.signInWithOidc')));
      await tester.pumpAndSettle();

      expect(configured, signedInConfig);
    });
  });

  testWidgets('tapping Sign in on a mobile platform drives signInMobile', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.iOS, () async {
      final store = InMemoryConfigStore();
      const signedInConfig = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'access-token',
        actor: 'Alice Example',
        oauthClientId: 'client-1',
        oauthRefreshToken: 'refresh-1',
      );

      final oidcController = _FakeOidcSignInController(store: store);

      AppConfig? configured;
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(oidcSupportedClient()),
            onConfigured: (c) => configured = c,
            oidcController: oidcController,
            capabilitiesClientFactory: oidcSupportedClient,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('setup.continue')));
      await tester.pumpAndSettle();

      oidcController.nextResult = signedInConfig;
      await tester.tap(find.byKey(const Key('setup.signInWithOidc')));
      await tester.pumpAndSettle();

      expect(oidcController.mobileSignInCalls, 1);
      expect(oidcController.desktopSignInCalls, 0);
      expect(configured, signedInConfig);
    });
  });
}

/// A minimal fake standing in for a real [OidcSignInController]: calling
/// [signInDesktop] or [signInMobile] immediately resolves to [nextResult]
/// (set by the test) as a success, without touching any real network,
/// socket, or browser sheet. Tracks call counts so a test can assert which
/// flow the screen actually drove for the platform it pinned.
class _FakeOidcSignInController extends OidcSignInController {
  _FakeOidcSignInController({required super.store})
    : super(launchUri: (_) async {});

  AppConfig? nextResult;
  int desktopSignInCalls = 0;
  int mobileSignInCalls = 0;

  @override
  Future<void> signInDesktop(String baseUrl) async {
    desktopSignInCalls++;
    final result = nextResult;
    if (result == null) return;
    value = OidcSignInSuccess(result);
  }

  @override
  Future<void> signInMobile(String baseUrl) async {
    mobileSignInCalls++;
    final result = nextResult;
    if (result == null) return;
    value = OidcSignInSuccess(result);
  }
}
