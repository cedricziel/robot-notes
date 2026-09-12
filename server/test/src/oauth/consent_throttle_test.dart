import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/consent_throttle.dart';
import 'package:test/test.dart';

/// A [Clock] a test can move forward at will, unlike [FixedClock] which
/// only advances by consuming pre-seeded instants one per call.
class _MutableClock implements Clock {
  _MutableClock(this._now);
  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

void main() {
  group('ConsentThrottle', () {
    test('is not blocked with no recorded failures', () {
      final throttle =
          ConsentThrottle(clock: _MutableClock(DateTime.utc(2026)));
      expect(throttle.isBlocked, isFalse);
    });

    test('is not blocked after 9 failures', () {
      final clock = _MutableClock(DateTime.utc(2026));
      final throttle = ConsentThrottle(clock: clock);
      for (var i = 0; i < 9; i++) {
        throttle.recordFailure('client-1');
      }
      expect(throttle.isBlocked, isFalse);
    });

    test('is blocked once 10 failures land within the window', () {
      final clock = _MutableClock(DateTime.utc(2026));
      final throttle = ConsentThrottle(clock: clock);
      for (var i = 0; i < 10; i++) {
        throttle.recordFailure('client-1');
      }
      expect(throttle.isBlocked, isTrue);
    });

    test('unblocks once the failures age out of the 60s window', () {
      final clock = _MutableClock(DateTime.utc(2026));
      final throttle = ConsentThrottle(clock: clock);
      for (var i = 0; i < 10; i++) {
        throttle.recordFailure('client-1');
      }
      expect(throttle.isBlocked, isTrue);

      clock.advance(const Duration(seconds: 61));
      expect(throttle.isBlocked, isFalse);
    });

    test('failures from different clients share the same global window', () {
      final clock = _MutableClock(DateTime.utc(2026));
      final throttle = ConsentThrottle(clock: clock);
      for (var i = 0; i < 5; i++) {
        throttle.recordFailure('client-a');
      }
      for (var i = 0; i < 5; i++) {
        throttle.recordFailure('client-b');
      }
      expect(throttle.isBlocked, isTrue);
    });

    test('recordFailure logs a warning naming only the client id', () {
      final logs = <LogRecord>[];
      ConsentThrottle(
        clock: _MutableClock(DateTime.utc(2026)),
        logger: Logger.detached('test')..onRecord.listen(logs.add),
      ).recordFailure('client-123');

      expect(logs, hasLength(1));
      expect(logs.single.level, Level.WARNING);
      expect(logs.single.message, contains('client-123'));
    });

    test('the recorded warning never mentions an API key value', () {
      // ConsentThrottle.recordFailure's signature takes only a client id —
      // structurally, there is no submitted-key parameter it could log,
      // even by mistake.
      final logs = <LogRecord>[];
      ConsentThrottle(
        clock: _MutableClock(DateTime.utc(2026)),
        logger: Logger.detached('test')..onRecord.listen(logs.add),
      ).recordFailure('client-123');

      expect(logs.single.message, isNot(contains('rn_')));
    });
  });
}
