import 'dart:convert';

import 'package:server/src/oidc/id_token.dart';
import 'package:server/src/oidc/jwks.dart';
import 'package:test/test.dart';

import '_id_token_test_helpers.dart';

void main() {
  const issuer = 'https://idp.example.com';
  const audience = 'robot-notes';
  const nonce = 'test-nonce-xyz';

  late TestRsaKeyPair rsa;
  late TestEcKeyPair ec;

  Map<String, dynamic> validPayload({
    String? sub,
    String? name,
    String? email,
    int? exp,
    String? iss,
    Object? aud,
    String? tokenNonce,
  }) {
    final now = DateTime.now().toUtc();
    return {
      'iss': iss ?? issuer,
      'aud': aud ?? audience,
      'sub': sub ?? 'user-123',
      'exp': exp ??
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'nonce': tokenNonce ?? nonce,
      if (name != null) 'name': name,
      if (email != null) 'email': email,
    };
  }

  JwksCache jwksFor(List<Map<String, dynamic>> keys) => JwksCache(
        jwksUri: 'https://idp.example.com/jwks.json',
        httpGet: (uri) async => jsonEncode({'keys': keys}),
      );

  setUp(() {
    rsa = generateTestRsaKeyPair();
    ec = generateTestEcKeyPair();
  });

  group('verifyIdToken success', () {
    test('a validly RS256-signed token verifies and yields its claims',
        () async {
      final token = signRs256(
        validPayload(name: 'Alice Example', email: 'alice@example.com'),
        rsa,
      );
      final claims = await verifyIdToken(
        token,
        issuer: issuer,
        audience: audience,
        nonce: nonce,
        jwks: jwksFor([rsa.jwk]),
      );
      expect(claims.sub, 'user-123');
      expect(claims.name, 'Alice Example');
      expect(claims.email, 'alice@example.com');
    });

    test('a validly ES256-signed token verifies and yields its claims',
        () async {
      final token = signEs256(validPayload(name: 'Bob Example'), ec);
      final claims = await verifyIdToken(
        token,
        issuer: issuer,
        audience: audience,
        nonce: nonce,
        jwks: jwksFor([ec.jwk]),
      );
      expect(claims.name, 'Bob Example');
    });

    test('aud as an array containing our client id verifies', () async {
      final token = signRs256(
        validPayload(aud: ['other-client', audience]),
        rsa,
      );
      final claims = await verifyIdToken(
        token,
        issuer: issuer,
        audience: audience,
        nonce: nonce,
        jwks: jwksFor([rsa.jwk]),
      );
      expect(claims.sub, 'user-123');
    });
  });

  group('verifyIdToken rejections', () {
    test('alg=none is rejected without a key lookup', () async {
      var lookedUp = false;
      final token = buildNoneAlgToken(validPayload());
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: JwksCache(
            jwksUri: 'https://idp.example.com/jwks.json',
            httpGet: (uri) async {
              lookedUp = true;
              return jsonEncode({
                'keys': [rsa.jwk],
              });
            },
          ),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.badAlgorithm,
          ),
        ),
      );
      expect(lookedUp, isFalse);
    });

    test('an unsupported algorithm is rejected', () async {
      final token = signRs256(validPayload(), rsa, algOverride: 'HS256');
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.badAlgorithm,
          ),
        ),
      );
    });

    test('a tampered signature is rejected', () async {
      final token = signRs256(validPayload(), rsa, corruptSignature: true);
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.badSignature,
          ),
        ),
      );
    });

    test('a signature from the wrong key is rejected', () async {
      final otherRsa = generateTestRsaKeyPair(kid: rsa.kid);
      final token = signRs256(validPayload(), otherRsa);
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.badSignature,
          ),
        ),
      );
    });

    test('wrong issuer is rejected', () async {
      final token = signRs256(
        validPayload(iss: 'https://not-the-idp.example.com'),
        rsa,
      );
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.wrongIssuer,
          ),
        ),
      );
    });

    test('wrong audience is rejected', () async {
      final token = signRs256(validPayload(aud: 'someone-else'), rsa);
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.wrongAudience,
          ),
        ),
      );
    });

    test('an expired token is rejected', () async {
      final expired = DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 5))
              .millisecondsSinceEpoch ~/
          1000;
      final token = signRs256(validPayload(exp: expired), rsa);
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.expired,
          ),
        ),
      );
    });

    test('a nonce mismatch is rejected', () async {
      final token = signRs256(validPayload(tokenNonce: 'wrong-nonce'), rsa);
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.nonceMismatch,
          ),
        ),
      );
    });

    test('an unknown kid is rejected', () async {
      final token = signRs256(validPayload(), rsa, kidOverride: 'no-such-kid');
      await expectLater(
        verifyIdToken(
          token,
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.unknownKey,
          ),
        ),
      );
    });

    test('a malformed token (wrong segment count) is rejected', () async {
      await expectLater(
        verifyIdToken(
          'not-a-jwt',
          issuer: issuer,
          audience: audience,
          nonce: nonce,
          jwks: jwksFor([rsa.jwk]),
        ),
        throwsA(
          isA<IdTokenVerificationException>().having(
            (e) => e.failure,
            'failure',
            IdTokenVerificationFailure.malformed,
          ),
        ),
      );
    });
  });

  group('missing name claim fallback', () {
    test('falls back to email, then sub, when name is absent', () async {
      final withEmail = signRs256(
        validPayload(email: 'only-email@example.com'),
        rsa,
      );
      final claims = await verifyIdToken(
        withEmail,
        issuer: issuer,
        audience: audience,
        nonce: nonce,
        jwks: jwksFor([rsa.jwk]),
      );
      expect(claims.name, isNull);
      expect(claims.email, 'only-email@example.com');
    });
  });
}
