import 'dart:async';
import 'dart:convert';

import 'package:app/src/auth/oidc_session_refresher.dart';
import 'package:app/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class CloseTrackingClient extends MockClient {
  CloseTrackingClient(super.fn);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  const session = AppConfig(
    baseUrl: 'https://notes.example',
    apiKey: 'old-access-token',
    actor: 'Alice Example',
    oauthClientId: 'client-1',
    oauthRefreshToken: 'old-refresh-token',
  );

  group('OidcSessionRefresher.refresh', () {
    testWidgets('timeout is retryable and closes the stalled client', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      final client = CloseTrackingClient((_) => response.future);
      final refresher = OidcSessionRefresher(clientFactory: () => client);
      final result = expectLater(
        refresher.refresh(session),
        throwsA(
          isA<OidcRefreshException>().having(
            (error) => error.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 30));
      await result;
      expect(client.closed, isTrue);
      response.complete(http.Response('{}', 200));
      await tester.pump();
    });

    test(
      'lost responses keep the retry identifier stable across reloads',
      () async {
        final requests = <String?>[];
        final refresher = OidcSessionRefresher(
          clientFactory: () => MockClient((request) async {
            requests.add(
              Uri.splitQueryString(request.body)['refresh_request_id'],
            );
            throw http.ClientException('response lost');
          }),
        );
        await expectLater(
          refresher.refresh(session),
          throwsA(isA<OidcRefreshException>()),
        );
        await expectLater(
          refresher.refresh(AppConfig.fromJson(session.toJson())),
          throwsA(isA<OidcRefreshException>()),
        );
        expect(requests.first, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(requests.last, requests.first);
        expect(requests.first, isNot(session.apiKey));
      },
    );

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

    test('malformed response requires a fresh sign-in', () async {
      final refresher = OidcSessionRefresher(
        clientFactory: () =>
            MockClient((_) async => http.Response('not json', 200)),
      );
      await expectLater(
        refresher.refresh(session),
        throwsA(
          isA<OidcRefreshException>().having(
            (error) => error.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
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
