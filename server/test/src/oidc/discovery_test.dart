import 'dart:convert';

import 'package:server/src/oidc/discovery.dart';
import 'package:test/test.dart';

void main() {
  group('fetchOidcDiscovery', () {
    test('extracts the three required endpoints from a well-formed document',
        () async {
      final doc = await fetchOidcDiscovery(
        'https://idp.example.com',
        httpGet: (uri) async {
          expect(
            uri.toString(),
            'https://idp.example.com/.well-known/openid-configuration',
          );
          return jsonEncode({
            'issuer': 'https://idp.example.com',
            'authorization_endpoint': 'https://idp.example.com/authorize',
            'token_endpoint': 'https://idp.example.com/token',
            'jwks_uri': 'https://idp.example.com/jwks.json',
          });
        },
      );

      expect(doc.authorizationEndpoint, 'https://idp.example.com/authorize');
      expect(doc.tokenEndpoint, 'https://idp.example.com/token');
      expect(doc.jwksUri, 'https://idp.example.com/jwks.json');
    });

    test('throws naming the issuer when the document is missing a field',
        () async {
      expect(
        () => fetchOidcDiscovery(
          'https://idp.example.com',
          httpGet: (uri) async => jsonEncode({
            'authorization_endpoint': 'https://idp.example.com/authorize',
            'token_endpoint': 'https://idp.example.com/token',
            // jwks_uri missing
          }),
        ),
        throwsA(
          isA<OidcDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('https://idp.example.com'),
          ),
        ),
      );
    });

    test('throws naming the issuer when the issuer is unreachable', () async {
      expect(
        () => fetchOidcDiscovery(
          'https://idp.example.com',
          httpGet: (uri) async => throw Exception('connection refused'),
        ),
        throwsA(
          isA<OidcDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('https://idp.example.com'),
          ),
        ),
      );
    });

    test('throws when the document is not valid JSON', () async {
      expect(
        () => fetchOidcDiscovery(
          'https://idp.example.com',
          httpGet: (uri) async => 'not json',
        ),
        throwsA(isA<OidcDiscoveryException>()),
      );
    });
  });
}
