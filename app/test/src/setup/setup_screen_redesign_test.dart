import 'dart:async';
import 'dart:convert';

import 'package:app/src/auth/oidc_sign_in_controller.dart';
import 'package:app/src/config/config_store.dart';
import 'package:app/src/setup/setup_controller.dart';
import 'package:app/src/setup/setup_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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

  SetupController setupController() => SetupController(
    store: InMemoryConfigStore(),
    clientFactory: () => MockClient((_) async => http.Response('', 200)),
  );

  group('width-capped layout', () {
    testWidgets(
      'the login card does not stretch edge to edge on a wide window',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: SetupScreen(
              controller: setupController(),
              onConfigured: (_) {},
            ),
          ),
        );

        final size = tester.getSize(find.byKey(const Key('setup.card')));
        expect(size.width, lessThanOrEqualTo(420));
      },
    );
  });

  group('live reachability check', () {
    testWidgets('shows a checking indicator while /healthz is in flight', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      final client = MockClient((_) => pending.future);

      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(),
            onConfigured: (_) {},
            capabilitiesClientFactory: () => client,
            capabilitiesDebounce: const Duration(milliseconds: 10),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        find.byKey(const Key('setup.reachability.checking')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('setup.reachability.ok')), findsNothing);
      expect(find.byKey(const Key('setup.reachability.error')), findsNothing);

      pending.complete(http.Response('{"status":"ok"}', 200));
      await tester.pumpAndSettle();
    });

    testWidgets('shows an ok indicator once /healthz responds 200', (
      tester,
    ) async {
      final client = MockClient(
        (_) async => http.Response('{"status":"ok"}', 200),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(),
            onConfigured: (_) {},
            capabilitiesClientFactory: () => client,
            capabilitiesDebounce: const Duration(milliseconds: 10),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('setup.reachability.ok')), findsOneWidget);
      expect(find.byKey(const Key('setup.reachability.error')), findsNothing);
    });

    testWidgets('shows an error indicator when the server cannot be reached', (
      tester,
    ) async {
      final client = MockClient(
        (_) async => throw http.ClientException('boom'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(),
            onConfigured: (_) {},
            capabilitiesClientFactory: () => client,
            capabilitiesDebounce: const Duration(milliseconds: 10),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('setup.reachability.error')), findsOneWidget);
      expect(find.byKey(const Key('setup.reachability.ok')), findsNothing);
    });

    testWidgets('a stale response does not override a newer check', (
      tester,
    ) async {
      final responses = <Completer<http.Response>>[];
      final client = MockClient((_) {
        final c = Completer<http.Response>();
        responses.add(c);
        return c.future;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            controller: setupController(),
            onConfigured: (_) {},
            capabilitiesClientFactory: () => client,
            capabilitiesDebounce: const Duration(milliseconds: 10),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example',
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(responses, hasLength(1));

      await tester.enterText(
        find.byKey(const Key('setup.baseUrl')),
        'https://notes.example.org',
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(responses, hasLength(2));

      // The newer (second) request resolves first, as reachable.
      responses[1].complete(http.Response('{"status":"ok"}', 200));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup.reachability.ok')), findsOneWidget);

      // The older (first) request resolves late, as an error. It must not
      // clobber the newer, already-settled "ok" state.
      responses[0].completeError(http.ClientException('boom'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup.reachability.ok')), findsOneWidget);
      expect(find.byKey(const Key('setup.reachability.error')), findsNothing);
    });
  });

  group('manual key entry disclosure', () {
    http.Client oidcSupportedClient() => MockClient((request) async {
      if (request.url.path == '/.well-known/oauth-authorization-server') {
        return http.Response(
          jsonEncode({'robotnotes_oidc_login_supported': true}),
          200,
        );
      }
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      return http.Response('not found', 404);
    });

    testWidgets(
      'starts collapsed behind a disclosure when sign-in is available',
      (tester) async {
        await withPlatform(TargetPlatform.macOS, () async {
          await tester.pumpWidget(
            MaterialApp(
              home: SetupScreen(
                controller: setupController(),
                onConfigured: (_) {},
                oidcController: OidcSignInController(
                  store: InMemoryConfigStore(),
                  launchUri: (_) async {},
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
          expect(find.byKey(const Key('setup.useApiKey')), findsOneWidget);
          expect(find.byKey(const Key('setup.apiKey')), findsNothing);
          expect(find.byKey(const Key('setup.actor')), findsNothing);
        });
      },
    );

    testWidgets('tapping "Use an API key instead" reveals manual entry', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.macOS, () async {
        await tester.pumpWidget(
          MaterialApp(
            home: SetupScreen(
              controller: setupController(),
              onConfigured: (_) {},
              oidcController: OidcSignInController(
                store: InMemoryConfigStore(),
                launchUri: (_) async {},
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

        await tester.tap(find.byKey(const Key('setup.useApiKey')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('setup.apiKey')), findsOneWidget);
        expect(find.byKey(const Key('setup.actor')), findsOneWidget);
        expect(find.byKey(const Key('setup.submit')), findsOneWidget);
      });
    });

    testWidgets(
      'manual entry stays visible with no disclosure when sign-in is unavailable',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SetupScreen(
              controller: setupController(),
              onConfigured: (_) {},
            ),
          ),
        );

        await tester.enterText(
          find.byKey(const Key('setup.baseUrl')),
          'https://notes.example',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('setup.continue')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('setup.useApiKey')), findsNothing);
        expect(find.byKey(const Key('setup.apiKey')), findsOneWidget);
        expect(find.byKey(const Key('setup.actor')), findsOneWidget);
      },
    );
  });
}
