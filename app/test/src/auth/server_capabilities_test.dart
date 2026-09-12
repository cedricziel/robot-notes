import 'dart:convert';

import 'package:app/src/auth/server_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('fetchServerCapabilities', () {
    test('supportsOidcLogin is true when the field is true', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/.well-known/oauth-authorization-server');
        return http.Response(
          jsonEncode({
            'issuer': 'https://notes.example',
            'robotnotes_oidc_login_supported': true,
          }),
          200,
        );
      });

      final caps = await fetchServerCapabilities(
        'https://notes.example',
        client: client,
      );
      expect(caps.supportsOidcLogin, isTrue);
    });

    test('supportsOidcLogin is false when the field is absent', () async {
      final client = MockClient(
        (request) async =>
            http.Response(jsonEncode({'issuer': 'https://notes.example'}), 200),
      );

      final caps = await fetchServerCapabilities(
        'https://notes.example',
        client: client,
      );
      expect(caps.supportsOidcLogin, isFalse);
    });

    test('supportsOidcLogin is false on a non-200 response', () async {
      final client = MockClient(
        (request) async => http.Response('not found', 404),
      );

      final caps = await fetchServerCapabilities(
        'https://notes.example',
        client: client,
      );
      expect(caps.supportsOidcLogin, isFalse);
    });

    test('supportsOidcLogin is false when the request throws', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('connection refused'),
      );

      final caps = await fetchServerCapabilities(
        'https://notes.example',
        client: client,
      );
      expect(caps.supportsOidcLogin, isFalse);
    });

    test(
      'supportsOidcLogin is false when the body is not valid JSON',
      () async {
        final client = MockClient(
          (request) async => http.Response('not json', 200),
        );

        final caps = await fetchServerCapabilities(
          'https://notes.example',
          client: client,
        );
        expect(caps.supportsOidcLogin, isFalse);
      },
    );
  });
}
