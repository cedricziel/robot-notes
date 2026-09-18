"""A small circuit breaker for ``RobotNotesClient``.

After enough consecutive failures against an unreachable server, calls pause for
a cooldown instead of piling up slow timeouts on every turn (prefetch runs once
per turn). The clock is injectable so tests can control elapsed time without
sleeping — production code omits it and gets ``time.monotonic``.
"""

from __future__ import annotations

import threading
import time
from typing import Callable

DEFAULT_THRESHOLD = 5
DEFAULT_COOLDOWN_SECS = 60.0


class CircuitBreaker:
    """Tracks consecutive failures and opens after ``threshold`` in a row.

    Not every failure counts — callers decide what qualifies (e.g. network errors
    and 5xx, but not a 404 or a version conflict) and only call ``record_failure``
    for those.
    """

    def __init__(
        self,
        *,
        threshold: int = DEFAULT_THRESHOLD,
        cooldown: float = DEFAULT_COOLDOWN_SECS,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._threshold = threshold
        self._cooldown = cooldown
        self._clock = clock
        self._lock = threading.Lock()
        self._consecutive_failures = 0
        self._open_until = 0.0

    @property
    def cooldown_seconds(self) -> float:
        return self._cooldown

    def is_open(self) -> bool:
        """True while the breaker is tripped; an expired cooldown resets the
        failure count so the next call is a fresh, uncounted attempt."""
        with self._lock:
            if self._consecutive_failures >= self._threshold and self._clock() < self._open_until:
                return True
            if self._consecutive_failures >= self._threshold:
                self._consecutive_failures = 0
            return False

    def record_success(self) -> None:
        with self._lock:
            self._consecutive_failures = 0

    def record_failure(self) -> None:
        with self._lock:
            self._consecutive_failures += 1
            if self._consecutive_failures >= self._threshold:
                self._open_until = self._clock() + self._cooldown
