import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';

/// Process-wide, non-persisted rate limit on failed `POST /oauth/authorize`
/// consent submissions.
///
/// Without it, the consent form is an unthrottled oracle for the
/// workspace's single static API key (see `Config.apiKey`): an attacker
/// with network access to `/oauth/authorize` can submit unlimited guesses
/// and learn each one's correctness from the response. There is exactly
/// one secret to protect and one caller-facing surface for it, so the
/// window is global rather than partitioned by client id or IP — a
/// per-partition limit would let an attacker reset it just by rotating
/// client registrations.
class ConsentThrottle {
  /// Creates a throttle. [clock] is injectable so tests can advance time
  /// without a real 60-second wait; [logger] is injectable so tests can
  /// capture the warning emitted by [recordFailure].
  ConsentThrottle({
    Clock clock = const Clock(),
    Logger? logger,
  })  : _clock = clock,
        _log = logger ?? Logger('oauth.consent_throttle');

  /// Once this many failures have landed within [_kWindow], every further
  /// submission is blocked until enough of them age out.
  static const int _kMaxFailures = 10;

  /// Width of the sliding window failures are counted within.
  static const Duration _kWindow = Duration(seconds: 60);

  final Clock _clock;
  final Logger _log;
  final List<DateTime> _failures = [];

  /// Whether a consent submission should be rejected outright — before
  /// even checking the API key — because [_kMaxFailures] failed attempts
  /// have already landed within the trailing [_kWindow].
  bool get isBlocked {
    _prune(_clock.nowUtc());
    return _failures.length >= _kMaxFailures;
  }

  /// Records a failed consent submission and logs a warning naming
  /// [clientId]. Takes no key or credential value: the submitted API key
  /// SHALL NEVER be logged, and this signature makes that structurally
  /// impossible rather than relying on the caller to redact it.
  void recordFailure(String clientId) {
    final now = _clock.nowUtc();
    _prune(now);
    _failures.add(now);
    _log.warning('Failed consent submission for client_id=$clientId');
  }

  void _prune(DateTime now) {
    _failures.removeWhere((t) => now.difference(t) >= _kWindow);
  }
}
