/// Indirection on `DateTime.now()` so tests can pin time without
/// stubbing globals. Everything that timestamps notes, locks, or events
/// SHALL go through a [Clock] instance — never `DateTime.now()` directly.
// ignore: one_member_abstracts
abstract class Clock {
  /// Returns the system UTC clock.
  const factory Clock() = _SystemClock;

  /// Returns the current instant in UTC.
  DateTime nowUtc();
}

class _SystemClock implements Clock {
  const _SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Test clock that returns a sequence of pre-seeded instants.
///
/// Each call to [nowUtc] consumes the head of the queue. When the queue
/// is exhausted the most recent value is returned (sticky), so tests can
/// seed only as many points as they care about and still drive arbitrary
/// numbers of writes.
class FixedClock implements Clock {
  /// Creates a clock that walks through [moments].
  FixedClock(List<DateTime> moments)
      : assert(moments.isNotEmpty, 'FixedClock needs at least one moment'),
        _moments = List<DateTime>.of(moments).map((d) => d.toUtc()).toList();

  /// Convenience constructor for a clock that returns [moment] forever.
  FixedClock.fixed(DateTime moment) : this([moment]);

  final List<DateTime> _moments;
  int _idx = 0;

  @override
  DateTime nowUtc() {
    final m = _moments[_idx];
    if (_idx + 1 < _moments.length) _idx++;
    return m;
  }
}
