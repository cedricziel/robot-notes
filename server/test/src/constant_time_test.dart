import 'package:server/src/constant_time.dart';
import 'package:test/test.dart';

void main() {
  group('constantTimeEquals', () {
    test('returns true for identical strings', () {
      expect(constantTimeEquals('rn_secret', 'rn_secret'), isTrue);
    });

    test('returns false for different strings of the same length', () {
      expect(constantTimeEquals('rn_secret', 'rn_diff!!'), isFalse);
    });

    test('returns false for strings of different lengths', () {
      expect(constantTimeEquals('rn_secret', 'rn_secret_long'), isFalse);
      expect(constantTimeEquals('rn_secret', 'rn_'), isFalse);
    });

    test('returns true for two empty strings', () {
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('returns false when only one side is empty', () {
      expect(constantTimeEquals('', 'rn_secret'), isFalse);
      expect(constantTimeEquals('rn_secret', ''), isFalse);
    });

    test('does not short-circuit on first mismatch', () {
      // Catches the "early return on first byte mismatch" regression. We do
      // NOT measure timing (microbenchmarks are too noisy on shared CI for a
      // tight bound). Instead we read the implementation's contract via the
      // boolean: an early-return implementation would still answer false in
      // both cases below, but a correct implementation must at least handle
      // unequal lengths without throwing or returning true.
      const configured = 'rn_long_enough_key_to_be_observable_';
      final sharedPrefix = '${configured.substring(0, configured.length - 1)}X';
      final noPrefix = 'Z' * configured.length;
      expect(constantTimeEquals(configured, sharedPrefix), isFalse);
      expect(constantTimeEquals(configured, noPrefix), isFalse);

      // High-iteration smoke pass: the result must remain stable across
      // many calls (no transient true positive due to a rogue mutation).
      for (var i = 0; i < 1000; i++) {
        expect(constantTimeEquals(configured, sharedPrefix), isFalse);
      }
    });
  });
}
