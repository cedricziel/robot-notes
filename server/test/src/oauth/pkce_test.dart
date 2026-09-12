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

    test('rejects a verifier shorter than 43 characters', () {
      final tooShort = _rfcVerifier.substring(0, 42);
      expect(
        pkceVerify(
          challenge: pkceS256Challenge(tooShort),
          verifier: tooShort,
        ),
        isFalse,
      );
    });

    test('rejects a verifier longer than 128 characters', () {
      // Three copies of the 43-char RFC vector: 129 characters.
      const tooLong = _rfcVerifier + _rfcVerifier + _rfcVerifier;
      expect(
        pkceVerify(
          challenge: pkceS256Challenge(tooLong),
          verifier: tooLong,
        ),
        isFalse,
      );
    });

    test(
        'rejects a verifier containing a character outside the RFC 7636 '
        'unreserved set', () {
      final invalid = '${_rfcVerifier.substring(0, 42)}!';
      expect(
        pkceVerify(
          challenge: pkceS256Challenge(invalid),
          verifier: invalid,
        ),
        isFalse,
      );
    });

    test('accepts every character in the RFC 7636 unreserved set', () {
      const verifier =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-';
      expect(verifier.length, inInclusiveRange(43, 128));
      expect(
        pkceVerify(
          challenge: pkceS256Challenge(verifier),
          verifier: verifier,
        ),
        isTrue,
      );
    });
  });
}
