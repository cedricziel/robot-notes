import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('ErrorCode', () {
    test('every value has a stable wire string and parses back', () {
      for (final code in ErrorCode.values) {
        final wire = code.wire;
        expect(wire, isNotEmpty);
        expect(ErrorCode.fromWire(wire), equals(code));
      }
    });

    test('fromWire returns null for unknown codes', () {
      expect(ErrorCode.fromWire('definitely_not_a_real_code'), isNull);
    });

    test('contains the codes referenced by the v1 specs', () {
      const expected = {
        'unauthorized',
        'not_found',
        'bad_request',
        'version_conflict',
        'precondition_required',
        'locked',
        'empty_query',
        'invalid_query',
        'invalid_ttl',
        'invite_not_found',
        'invite_burned',
        'unknown_type',
        'auth_failed',
        'auth_timeout',
        'internal_error',
      };
      final actual = ErrorCode.values.map((c) => c.wire).toSet();
      expect(expected.difference(actual), isEmpty);
    });
  });

  group('ErrorEnvelope', () {
    test('round-trips with just an error code', () {
      final env = ErrorEnvelope(code: ErrorCode.unauthorized);
      final json = env.toJson();
      expect(json, {'error': 'unauthorized'});
      expect(ErrorEnvelope.fromJson(json), equals(env));
    });

    test('round-trips with message and details', () {
      final env = ErrorEnvelope(
        code: ErrorCode.versionConflict,
        message: 'note version drifted',
        details: {'current_version': 7},
      );
      final json = env.toJson();
      expect(json['error'], 'version_conflict');
      expect(json['message'], 'note version drifted');
      expect(json['current_version'], 7);
      final back = ErrorEnvelope.fromJson(json);
      expect(back, equals(env));
    });

    test('fromJson rejects an unknown error code', () {
      expect(
        () => ErrorEnvelope.fromJson({'error': 'mystery'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
