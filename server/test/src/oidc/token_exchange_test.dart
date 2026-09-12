import 'dart:convert';

import 'package:server/src/oidc/token_exchange.dart';
import 'package:test/test.dart';

void main() {
  group('exchangeCodeForIdToken', () {
    test('posts the expected form fields and returns id_token', () async {
      Uri? postedUri;
      Map<String, String>? postedForm;
      final idToken = await exchangeCodeForIdToken(
        tokenEndpoint: 'https://idp.example.com/token',
        code: 'auth-code-abc',
        redirectUri: 'https://notes.example.com/oauth/oidc/callback',
        codeVerifier: 'verifier-xyz',
        clientId: 'robot-notes',
        clientSecret: 'shh',
        httpPost: (uri, form) async {
          postedUri = uri;
          postedForm = form;
          return jsonEncode({'id_token': 'a.b.c', 'token_type': 'Bearer'});
        },
      );

      expect(idToken, 'a.b.c');
      expect(postedUri.toString(), 'https://idp.example.com/token');
      expect(postedForm, {
        'grant_type': 'authorization_code',
        'code': 'auth-code-abc',
        'redirect_uri': 'https://notes.example.com/oauth/oidc/callback',
        'code_verifier': 'verifier-xyz',
        'client_id': 'robot-notes',
        'client_secret': 'shh',
      });
    });

    test('throws when the response has no id_token', () async {
      await expectLater(
        exchangeCodeForIdToken(
          tokenEndpoint: 'https://idp.example.com/token',
          code: 'auth-code-abc',
          redirectUri: 'https://notes.example.com/oauth/oidc/callback',
          codeVerifier: 'verifier-xyz',
          clientId: 'robot-notes',
          clientSecret: 'shh',
          httpPost: (uri, form) async => jsonEncode({'access_token': 'unused'}),
        ),
        throwsA(isA<OidcTokenExchangeException>()),
      );
    });

    test('throws when the response is not valid JSON', () async {
      await expectLater(
        exchangeCodeForIdToken(
          tokenEndpoint: 'https://idp.example.com/token',
          code: 'auth-code-abc',
          redirectUri: 'https://notes.example.com/oauth/oidc/callback',
          codeVerifier: 'verifier-xyz',
          clientId: 'robot-notes',
          clientSecret: 'shh',
          httpPost: (uri, form) async => 'not json',
        ),
        throwsA(isA<OidcTokenExchangeException>()),
      );
    });

    test('throws naming the endpoint when the request itself fails', () async {
      await expectLater(
        exchangeCodeForIdToken(
          tokenEndpoint: 'https://idp.example.com/token',
          code: 'auth-code-abc',
          redirectUri: 'https://notes.example.com/oauth/oidc/callback',
          codeVerifier: 'verifier-xyz',
          clientId: 'robot-notes',
          clientSecret: 'shh',
          httpPost: (uri, form) async => throw Exception('connection reset'),
        ),
        throwsA(
          isA<OidcTokenExchangeException>().having(
            (e) => e.message,
            'message',
            contains('https://idp.example.com/token'),
          ),
        ),
      );
    });
  });
}
