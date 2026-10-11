from __future__ import annotations

import threading


class MemoryHealth:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._states = {name: {"state": "not_attempted"} for name in ("recall", "mirror", "transcript")}
        self._generations = dict.fromkeys(self._states, 0)

    def begin(self, operation: str) -> int:
        with self._lock:
            self._generations[operation] += 1
            self._states[operation] = {"state": "in_progress"}
            return self._generations[operation]

    def finish(self, operation: str, generation: int, state: str, reason: str | None = None, *, source_unknown: bool | None = None) -> None:
        with self._lock:
            if generation == self._generations[operation]:
                self._states[operation] = {"state": state, **({"reason": reason} if reason else {}),
                                           **({"source_unknown": source_unknown} if source_unknown is not None else {})}

    def snapshot(self) -> dict:
        with self._lock:
            return {name: dict(state) for name, state in self._states.items()}
