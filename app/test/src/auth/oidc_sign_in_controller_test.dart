import 'dart:convert';

import 'package:app/src/auth/oidc_sign_in_controller.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('OidcSignInController.signInDesktop', () {
    late InMemoryConfigStore store;

    setUp(() {
      store = InMemoryConfigStore();
    });

    Future<http.Response> Function(http.Request) tokenExchangeHandler({
      String accessToken = 'access-token-xyz',
      String refreshToken = 'refresh-token-xyz',
      String actor = 'Alice Example',
    }) => (request) async {
      if (request.url.path == '/oauth/register') {
        return http.Response(jsonEncode({'client_id': 'client-abc'}), 201);
      }
      if (request.url.path == '/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': accessToken,
            'refresh_token': refreshToken,
            'actor': actor,
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
        );
      }
      throw StateError('unexpected request: ${request.url}');
    };

    test(
      'completes successfully end to end against a fake loopback callback',
      () async {
        final mock = MockClient(tokenExchangeHandler());
        Uri? launched;
        final controller = OidcSignInController(
          store: store,
          clientFactory: () => mock,
          launchUri: (uri) async => launched = uri,
        );

        // Drive the loopback callback in the background, as the "browser"
        // would after the user approves consent.
        final signInFuture = controller.signInDesktop('https://notes.example');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final capturedState = launched!.queryParameters['state']!;
        final redirectUri = launched!.queryParameters['redirect_uri']!;
        await http.get(
          Uri.parse(redirectUri).replace(
            queryParameters: {'code': 'auth-code-abc', 'state': capturedState},
          ),
        );

        await signInFuture;

        if (controller.value case final OidcSignInFailed f) {
          fail('sign-in failed: ${f.message}');
        }
        expect(controller.value, isA<OidcSignInSuccess>());
        final config = (controller.value as OidcSignInSuccess).config;
        expect(config.apiKey, 'access-token-xyz');
        expect(config.oauthRefreshToken, 'refresh-token-xyz');
        expect(config.actor, 'Alice Example');
        expect(config.baseUrl, 'https://notes.example');
        expect(await store.read(), equals(config));
      },
    );

    test('a provider error is surfaced as a failure', () async {
      final mock = MockClient(tokenExchangeHandler());
      Uri? launched;
      final controller = OidcSignInController(
        store: store,
        clientFactory: () => mock,
        launchUri: (uri) async => launched = uri,
      );

      final signInFuture = controller.signInDesktop('https://notes.example');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final redirectUri = launched!.queryParameters['redirect_uri']!;
      await http.get(
        Uri.parse(
          redirectUri,
        ).replace(queryParameters: {'error': 'access_denied'}),
      );

      await signInFuture;

      expect(controller.value, isA<OidcSignInFailed>());
      expect(await store.read(), isNull);
    });

    test(
      'a mismatched state is rejected without persisting anything',
      () async {
        final mock = MockClient(tokenExchangeHandler());
        Uri? launched;
        final controller = OidcSignInController(
          store: store,
          clientFactory: () => mock,
          launchUri: (uri) async => launched = uri,
        );

        final signInFuture = controller.signInDesktop('https://notes.example');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final redirectUri = launched!.queryParameters['redirect_uri']!;
        await http.get(
          Uri.parse(redirectUri).replace(
            queryParameters: {'code': 'auth-code-abc', 'state': 'wrong-state'},
          ),
        );

        await signInFuture;

        expect(controller.value, isA<OidcSignInFailed>());
        expect(await store.read(), isNull);
      },
    );
  });

  group('OidcSignInController.signInMobile', () {
    late InMemoryConfigStore store;

    setUp(() {
      store = InMemoryConfigStore();
    });

    Future<http.Response> Function(http.Request) tokenExchangeHandler({
      String accessToken = 'access-token-xyz',
      String refreshToken = 'refresh-token-xyz',
      String actor = 'Alice Example',
    }) => (request) async {
      if (request.url.path == '/oauth/register') {
        return http.Response(jsonEncode({'client_id': 'client-abc'}), 201);
      }
      if (request.url.path == '/oauth/token') {
        return http.Response(
          jsonEncode({
            'access_token': accessToken,
            'refresh_token': refreshToken,
            'actor': actor,
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
        );
      }
      throw StateError('unexpected request: ${request.url}');
    };

    test(
      'completes successfully end to end against a fake browser-sheet '
      'callback',
      () async {
        final mock = MockClient(tokenExchangeHandler());
        String? capturedUrl;
        String? capturedScheme;
        final controller = OidcSignInController(
          store: store,
          clientFactory: () => mock,
          launchUri: (_) async {},
          webAuthenticate: ({required url, required callbackUrlScheme}) async {
            capturedUrl = url;
            capturedScheme = callbackUrlScheme;
            final state = Uri.parse(url).queryParameters['state']!;
            return '$kMobileOidcRedirectUri?code=auth-code-abc&state=$state';
          },
        );

        await controller.signInMobile('https://notes.example');

        expect(capturedScheme, kMobileOidcCallbackScheme);
        expect(
          Uri.parse(capturedUrl!).queryParameters['redirect_uri'],
          kMobileOidcRedirectUri,
        );
        if (controller.value case final OidcSignInFailed f) {
          fail('sign-in failed: ${f.message}');
        }
        expect(controller.value, isA<OidcSignInSuccess>());
        final config = (controller.value as OidcSignInSuccess).config;
        expect(config.apiKey, 'access-token-xyz');
        expect(config.oauthRefreshToken, 'refresh-token-xyz');
        expect(config.actor, 'Alice Example');
        expect(config.baseUrl, 'https://notes.example');
        expect(await store.read(), equals(config));
      },
    );

    test('a provider error is surfaced as a failure', () async {
      final mock = MockClient(tokenExchangeHandler());
      final controller = OidcSignInController(
        store: store,
        clientFactory: () => mock,
        launchUri: (_) async {},
        webAuthenticate: ({required url, required callbackUrlScheme}) async {
          final state = Uri.parse(url).queryParameters['state']!;
          return '$kMobileOidcRedirectUri?error=access_denied&state=$state';
        },
      );

      await controller.signInMobile('https://notes.example');

      expect(controller.value, isA<OidcSignInFailed>());
      expect(await store.read(), isNull);
    });

    test(
      'a mismatched state is rejected without persisting anything',
      () async {
        final mock = MockClient(tokenExchangeHandler());
        final controller = OidcSignInController(
          store: store,
          clientFactory: () => mock,
          launchUri: (_) async {},
          webAuthenticate: ({required url, required callbackUrlScheme}) async {
            return '$kMobileOidcRedirectUri'
                '?code=auth-code-abc&state=wrong-state';
          },
        );

        await controller.signInMobile('https://notes.example');

        expect(controller.value, isA<OidcSignInFailed>());
        expect(await store.read(), isNull);
      },
    );

    test(
      'the user dismissing the browser sheet is surfaced as a failure',
      () async {
        final mock = MockClient(tokenExchangeHandler());
        final controller = OidcSignInController(
          store: store,
          clientFactory: () => mock,
          launchUri: (_) async {},
          webAuthenticate:
              ({required url, required callbackUrlScheme}) async {
                throw Exception('user cancelled');
              },
        );

        await controller.signInMobile('https://notes.example');

        expect(controller.value, isA<OidcSignInFailed>());
        expect(await store.read(), isNull);
      },
    );
  });

  group('OidcSignInController.resumeWebSignInIfPending', () {
    late InMemoryConfigStore store;

    setUp(() {
      store = InMemoryConfigStore();
    });

    test('completes the exchange for a matching pending login', () async {
      await store.writePendingOidcLogin(
        const PendingOidcLogin(
          baseUrl: 'https://notes.example',
          clientId: 'client-abc',
          codeVerifier: 'verifier-xyz',
          state: 'state-abc',
          redirectUri: 'https://notes.example/',
        ),
      );
      final mock = MockClient((request) async {
        expect(request.url.path, '/oauth/token');
        final form = Uri.splitQueryString(request.body);
        expect(form['code_verifier'], 'verifier-xyz');
        return http.Response(
          jsonEncode({
            'access_token': 'access-token-xyz',
            'refresh_token': 'refresh-token-xyz',
            'actor': 'Alice Example',
          }),
          200,
        );
      });
      final controller = OidcSignInController(
        store: store,
        clientFactory: () => mock,
        launchUri: (uri) async {},
      );

      await controller.resumeWebSignInIfPending(
        Uri.parse('https://notes.example/?code=abc&state=state-abc'),
      );

      expect(controller.value, isA<OidcSignInSuccess>());
      expect(await store.readPendingOidcLogin(), isNull);
    });

    test('does nothing when the URL has no callback parameters', () async {
      final controller = OidcSignInController(
        store: store,
        clientFactory: () => throw StateError('should not be called'),
        launchUri: (uri) async {},
      );

      await controller.resumeWebSignInIfPending(
        Uri.parse('https://notes.example/'),
      );

      expect(controller.value, isA<OidcSignInIdle>());
    });

    test('does nothing when there is no matching pending login', () async {
      final controller = OidcSignInController(
        store: store,
        clientFactory: () => throw StateError('should not be called'),
        launchUri: (uri) async {},
      );

      await controller.resumeWebSignInIfPending(
        Uri.parse('https://notes.example/?code=abc&state=unknown-state'),
      );

      expect(controller.value, isA<OidcSignInIdle>());
    });
  });
}
