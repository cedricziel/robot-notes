import 'package:server/src/oauth/pkce.dart';
import 'package:test/test.dart';

// RFC 7636 Appendix B test vector.
const _rfcVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const _rfcChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

void main() {
  group('pkceS256Challenge', () {
    test('matches the RFC 7636 appendix B vector', () {
      expect(pkceS256Challenge(_rfcVerifier), _rfcChallenge);
    });
  });

  group('pkceVerify', () {
    test('accepts the matching verifier for a challenge', () {
      expect(
        pkceVerify(challenge: _rfcChallenge, verifier: _rfcVerifier),
        isTrue,
      );
    });

    test('rejects a mismatched verifier', () {
      expect(
        pkceVerify(challenge: _rfcChallenge, verifier: 'wrong-verifier'),
        isFalse,
      );
    });

    test('rejects a challenge that is not valid base64url', () {
      expect(
        pkceVerify(challenge: 'not a challenge!!', verifier: _rfcVerifier),
        isFalse,
      );
    });

    test('does not throw for a non-ASCII verifier', () {
      expect(
        () => pkceVerify(challenge: _rfcChallenge, verifier: 'café'),
        returnsNormally,
      );
      expect(
        pkceVerify(challenge: _rfcChallenge, verifier: 'café'),
        isFalse,
      );
    });
  });
}
