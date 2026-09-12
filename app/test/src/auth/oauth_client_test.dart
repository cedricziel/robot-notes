import 'dart:convert';

import 'package:app/src/auth/oauth_client.dart';
import 'package:app/src/config/config_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('OAuthClient.ensureRegistered', () {
    test(
      'registers via POST /oauth/register and caches the client_id',
      () async {
        var registerCalls = 0;
        final store = InMemoryConfigStore();
        final mock = MockClient((request) async {
          registerCalls++;
          expect(request.url.path, '/oauth/register');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['redirect_uris'], ['http://127.0.0.1:12345/callback']);
          return http.Response(
            jsonEncode({
              'client_id': 'client-abc',
              'redirect_uris': ['http://127.0.0.1:12345/callback'],
              'token_endpoint_auth_method': 'none',
            }),
            201,
          );
        });
        final oauthClient = OAuthClient(
          store: store,
          clientFactory: () => mock,
        );

        final clientId = await oauthClient.ensureRegistered(
          baseUrl: 'https://notes.example',
          redirectUri: 'http://127.0.0.1:12345/callback',
        );

        expect(clientId, 'client-abc');
        expect(registerCalls, 1);
        expect(
          await store.readRegisteredOAuthClientId('https://notes.example'),
          'client-abc',
        );
      },
    );

    test(
      'a cached client id is reused without a new registration call',
      () async {
        final store = InMemoryConfigStore();
        await store.writeRegisteredOAuthClientId(
          'https://notes.example',
          'cached-client',
        );
        final mock = MockClient((request) async {
          fail('should not register again when a client id is cached');
        });
        final oauthClient = OAuthClient(
          store: store,
          clientFactory: () => mock,
        );

        final clientId = await oauthClient.ensureRegistered(
          baseUrl: 'https://notes.example',
          redirectUri: 'http://127.0.0.1:12345/callback',
        );

        expect(clientId, 'cached-client');
      },
    );

    test('a cached client id for a different base URL is not reused', () async {
      final store = InMemoryConfigStore();
      await store.writeRegisteredOAuthClientId(
        'https://other.example',
        'other-client',
      );
      var registerCalls = 0;
      final mock = MockClient((request) async {
        registerCalls++;
        return http.Response(jsonEncode({'client_id': 'new-client'}), 201);
      });
      final oauthClient = OAuthClient(store: store, clientFactory: () => mock);

      final clientId = await oauthClient.ensureRegistered(
        baseUrl: 'https://notes.example',
        redirectUri: 'http://127.0.0.1:12345/callback',
      );

      expect(clientId, 'new-client');
      expect(registerCalls, 1);
    });

    test('throws when registration does not return 201', () async {
      final store = InMemoryConfigStore();
      final mock = MockClient(
        (request) async => http.Response('server error', 500),
      );
      final oauthClient = OAuthClient(store: store, clientFactory: () => mock);

      await expectLater(
        oauthClient.ensureRegistered(
          baseUrl: 'https://notes.example',
          redirectUri: 'http://127.0.0.1:12345/callback',
        ),
        throwsA(isA<OAuthClientRegistrationException>()),
      );
    });

    test('throws when the response has no client_id', () async {
      final store = InMemoryConfigStore();
      final mock = MockClient(
        (request) async => http.Response(jsonEncode({}), 201),
      );
      final oauthClient = OAuthClient(store: store, clientFactory: () => mock);

      await expectLater(
        oauthClient.ensureRegistered(
          baseUrl: 'https://notes.example',
          redirectUri: 'http://127.0.0.1:12345/callback',
        ),
        throwsA(isA<OAuthClientRegistrationException>()),
      );
    });
  });

  group('OAuthClient.buildAuthorizeUri', () {
    test('builds a correct PKCE authorize URL with resource and scope', () {
      final store = InMemoryConfigStore();
      final oauthClient = OAuthClient(
        store: store,
        clientFactory: http.Client.new,
      );

      final uri = oauthClient.buildAuthorizeUri(
        baseUrl: 'https://notes.example',
        clientId: 'client-abc',
        redirectUri: 'http://127.0.0.1:12345/callback',
        codeChallenge: 'challenge-xyz',
        state: 'state-123',
      );

      expect(uri.origin, 'https://notes.example');
      expect(uri.path, '/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'client-abc');
      expect(
        uri.queryParameters['redirect_uri'],
        'http://127.0.0.1:12345/callback',
      );
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['code_challenge'], 'challenge-xyz');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['scope'], 'notes:read notes:write');
      expect(uri.queryParameters['resource'], 'https://notes.example');
      expect(uri.queryParameters['state'], 'state-123');
    });
  });

  group('PKCE helpers', () {
    test('generatePkceVerifier produces a valid-length verifier', () {
      final verifier = generatePkceVerifier();
      expect(verifier.length, greaterThanOrEqualTo(43));
      expect(verifier.length, lessThanOrEqualTo(128));
      expect(RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(verifier), isTrue);
    });

    test('generatePkceVerifier produces different verifiers each call', () {
      expect(generatePkceVerifier(), isNot(generatePkceVerifier()));
    });

    test('pkceS256Challenge matches the RFC 7636 appendix B vector', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        pkceS256Challenge(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('pkceS256Challenge matches sha256 base64url of the verifier', () {
      const verifier = 'some-random-verifier-value-1234567890';
      final expected = base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');
      expect(pkceS256Challenge(verifier), expected);
    });
  });
}
