import 'dart:convert';

import 'package:server/src/oidc/jwks.dart';
import 'package:test/test.dart';

Map<String, dynamic> _rsaJwk(String kid) => {
      'kty': 'RSA',
      'kid': kid,
      'alg': 'RS256',
      'use': 'sig',
      'n': 'n-value-$kid',
      'e': 'AQAB',
    };

void main() {
  group('JwksCache', () {
    test('resolves a key present in the initial fetch', () async {
      var fetches = 0;
      final cache = JwksCache(
        jwksUri: 'https://idp.example.com/jwks.json',
        httpGet: (uri) async {
          fetches++;
          return jsonEncode({
            'keys': [_rsaJwk('key-1')],
          });
        },
      );

      final key = await cache.keyForId('key-1');
      expect(key, isNotNull);
      expect(key!.kid, 'key-1');
      expect(fetches, 1);
    });

    test('caches keys across lookups without refetching', () async {
      var fetches = 0;
      final cache = JwksCache(
        jwksUri: 'https://idp.example.com/jwks.json',
        httpGet: (uri) async {
          fetches++;
          return jsonEncode({
            'keys': [_rsaJwk('key-1')],
          });
        },
      );

      await cache.keyForId('key-1');
      await cache.keyForId('key-1');
      expect(fetches, 1);
    });

    test('refetches exactly once when a kid is not in the cache', () async {
      var fetches = 0;
      final cache = JwksCache(
        jwksUri: 'https://idp.example.com/jwks.json',
        httpGet: (uri) async {
          fetches++;
          // Simulate the provider rotating in a new key on the second
          // fetch — the one the cache doesn't have yet.
          final keys = fetches == 1
              ? [_rsaJwk('key-1')]
              : [_rsaJwk('key-1'), _rsaJwk('key-2')];
          return jsonEncode({'keys': keys});
        },
      );

      await cache.keyForId('key-1');
      final key2 = await cache.keyForId('key-2');
      expect(key2, isNotNull);
      expect(key2!.kid, 'key-2');
      expect(fetches, 2);
    });

    test(
        'returns null (not another refetch) when the key still is not '
        'found after one refetch', () async {
      var fetches = 0;
      final cache = JwksCache(
        jwksUri: 'https://idp.example.com/jwks.json',
        httpGet: (uri) async {
          fetches++;
          return jsonEncode({
            'keys': [_rsaJwk('key-1')],
          });
        },
      );

      // Prime the cache with an initial fetch, so the lookup below is a
      // genuine cache-miss-triggers-one-refetch case, not the bootstrap
      // fetch every first-ever lookup requires.
      await cache.keyForId('key-1');

      final key = await cache.keyForId('does-not-exist');
      expect(key, isNull);
      expect(fetches, 2);
    });
  });

  group('Jwk algorithm allowlist', () {
    test('RS256 and ES256 keys are accepted', () {
      expect(isAllowedJwsAlgorithm('RS256'), isTrue);
      expect(isAllowedJwsAlgorithm('ES256'), isTrue);
    });

    test('none and other algorithms are rejected', () {
      expect(isAllowedJwsAlgorithm('none'), isFalse);
      expect(isAllowedJwsAlgorithm('HS256'), isFalse);
      expect(isAllowedJwsAlgorithm('RS512'), isFalse);
    });
  });
}
