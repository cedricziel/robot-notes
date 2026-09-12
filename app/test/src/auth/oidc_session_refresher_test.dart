import 'dart:convert';

import 'package:app/src/auth/oidc_session_refresher.dart';
import 'package:app/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const session = AppConfig(
    baseUrl: 'https://notes.example',
    apiKey: 'old-access-token',
    actor: 'Alice Example',
    oauthClientId: 'client-1',
    oauthRefreshToken: 'old-refresh-token',
  );

  group('OidcSessionRefresher.refresh', () {
    test('posts the refresh grant and returns the rotated session', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/oauth/token');
        final form = Uri.splitQueryString(request.body);
        expect(form['grant_type'], 'refresh_token');
        expect(form['refresh_token'], 'old-refresh-token');
        expect(form['client_id'], 'client-1');
        return http.Response(
          jsonEncode({
            'access_token': 'new-access-token',
            'refresh_token': 'new-refresh-token',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
        );
      });
      final refresher = OidcSessionRefresher(clientFactory: () => mock);

      final refreshed = await refresher.refresh(session);

      expect(refreshed.apiKey, 'new-access-token');
      expect(refreshed.oauthRefreshToken, 'new-refresh-token');
      expect(refreshed.baseUrl, session.baseUrl);
      expect(refreshed.actor, session.actor);
      expect(refreshed.oauthClientId, session.oauthClientId);
    });

    test('throws when the refresh token is rejected', () async {
      final mock = MockClient(
        (request) async =>
            http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      );
      final refresher = OidcSessionRefresher(clientFactory: () => mock);

      await expectLater(
        refresher.refresh(session),
        throwsA(isA<OidcRefreshException>()),
      );
    });

    test('throws when the response has no tokens', () async {
      final mock = MockClient(
        (request) async => http.Response(jsonEncode({}), 200),
      );
      final refresher = OidcSessionRefresher(clientFactory: () => mock);

      await expectLater(
        refresher.refresh(session),
        throwsA(isA<OidcRefreshException>()),
      );
    });

    test('throws immediately for a manual (non-OIDC) session', () async {
      const manual = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'rn_manual',
        actor: 'Alice',
      );
      final refresher = OidcSessionRefresher(
        clientFactory: () => throw StateError('should not be called'),
      );

      await expectLater(
        refresher.refresh(manual),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
