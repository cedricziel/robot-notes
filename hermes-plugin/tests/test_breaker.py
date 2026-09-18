from robot_notes.breaker import CircuitBreaker


class FakeClock:
    def __init__(self, now: float = 0.0):
        self._now = now

    def __call__(self) -> float:
        return self._now

    def advance(self, seconds: float) -> None:
        self._now += seconds


def test_closed_by_default():
    breaker = CircuitBreaker(clock=FakeClock())
    assert breaker.is_open() is False


def test_stays_closed_below_threshold():
    clock = FakeClock()
    breaker = CircuitBreaker(threshold=5, clock=clock)

    for _ in range(4):
        breaker.record_failure()

    assert breaker.is_open() is False


def test_opens_after_threshold_consecutive_failures():
    clock = FakeClock()
    breaker = CircuitBreaker(threshold=5, clock=clock)

    for _ in range(5):
        breaker.record_failure()

    assert breaker.is_open() is True


def test_a_success_resets_the_failure_count():
    clock = FakeClock()
    breaker = CircuitBreaker(threshold=5, clock=clock)

    for _ in range(4):
        breaker.record_failure()
    breaker.record_success()
    for _ in range(4):
        breaker.record_failure()

    assert breaker.is_open() is False


def test_closes_again_after_the_cooldown_elapses():
    clock = FakeClock()
    breaker = CircuitBreaker(threshold=5, cooldown=60.0, clock=clock)

    for _ in range(5):
        breaker.record_failure()
    assert breaker.is_open() is True

    clock.advance(60.0)

    assert breaker.is_open() is False


def test_a_failure_right_after_cooldown_expiry_reopens_the_breaker():
    clock = FakeClock()
    breaker = CircuitBreaker(threshold=5, cooldown=60.0, clock=clock)

    for _ in range(5):
        breaker.record_failure()
    clock.advance(60.0)
    assert breaker.is_open() is False  # cooldown reset the counter to 0

    for _ in range(4):
        breaker.record_failure()
    assert breaker.is_open() is False

    breaker.record_failure()
    assert breaker.is_open() is True


def test_cooldown_seconds_exposes_the_configured_value():
    breaker = CircuitBreaker(cooldown=42.0, clock=FakeClock())
    assert breaker.cooldown_seconds == 42.0
