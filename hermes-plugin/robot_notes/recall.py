"""Recall scoping: a per-(session, query) prefetch cache, trivial-prompt gating, and the
``RecallStatus`` payload behind the recall indicator.

``RecallStatus`` and ``is_trivial_prompt`` are hermes-agent's own contract (see
``agent/memory_provider.py`` upstream). This module prefers the real definitions —
through the sibling ``_hermes_compat`` shim once it lands, or straight from
``agent.memory_provider`` when this plugin runs inside a Hermes process — and only
falls back to a local copy of both so this package's test suite stays importable
without a hermes-agent checkout on the path.
"""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass
from typing import Callable, Dict, Optional, Tuple

try:
    from ._hermes_compat import RecallStatus, is_trivial_prompt  # type: ignore
except ImportError:
    try:
        from agent.memory_provider import RecallStatus, is_trivial_prompt  # type: ignore
    except ImportError:
        # Copied verbatim from hermes-agent's agent/memory_provider.py so behaviour
        # matches upstream exactly until one of the imports above is available.
        _TRIVIAL_PROMPT_RE = re.compile(
            r'^(yes|no|ok|okay|sure|thanks|thank you|y|n|yep|nope|yeah|nah|'
            r'hi|hey|hello|yo|sup|'
            r'continue|go ahead|do it|proceed|got it|cool|nice|great|done|next|lgtm|k)'
            r'[\s!?.:;,"' + "'" + r'~‘’“”—–…()\[\]{}<>*&^%$#@!+=` ]*$',
            re.IGNORECASE,
        )

        @dataclass(frozen=True)
        class RecallStatus:  # type: ignore[no-redef]
            """What the last prefetch injected, for the recall indicator line.
            ``glyph`` defaults to the upstream brain emoji; providers may override it."""

            provider_label: str
            count: int
            glyph: str = "\U0001f9e0"

        def is_trivial_prompt(text: Optional[str]) -> bool:  # type: ignore[no-redef]
            """True for empty input, slash commands and bare greetings/acknowledgements."""
            stripped = (text or "").strip()
            if not stripped or stripped.startswith("/"):
                return True
            return bool(_TRIVIAL_PROMPT_RE.match(stripped))


# A prefetch/search result: the formatted block ready for injection ("" if nothing
# matched) alongside how many notes it came from.
SearchResult = Tuple[str, int]


class RecallCache:
    """Background-prefetch cache keyed by ``(session_id, query)``, plus the bookkeeping
    ``recall_status()`` needs to describe only the most recent :meth:`prefetch` call.

    Keying by session as well as query is what stops one session's recall from
    leaking into another's when a single provider instance is shared across sessions
    (e.g. behind a gateway); keying by query as well as session is what stops a cached
    result from being injected against a prompt it was never actually recalled for.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: Dict[Tuple[str, str], SearchResult] = {}
        self._generation = 0
        self.thread: Optional[threading.Thread] = None
        self._last_count: Optional[int] = None

    def queue(
        self,
        session_id: str,
        query: str,
        run_search: Callable[[str], SearchResult],
        *,
        spawn_thread: Callable[..., threading.Thread],
    ) -> None:
        """Runs ``run_search(query)`` off the caller's thread and, if this is still the
        most recently queued search when it finishes, stores the result under
        ``(session_id, query)`` for :meth:`consume` to pick up. A generation counter
        stops a slow, superseded search from clobbering a fresher one that already
        landed — the same guard the previous single-slot cache used.

        ``spawn_thread`` is the caller's ``spawn_context_thread`` (never a bare
        ``threading.Thread``): under the Hermes host, profile home and the per-turn
        secret scope live in contextvars, and only that helper carries them onto the
        background thread. It's injected rather than imported here so the single
        module-level name callers monkeypatch (``robot_notes.spawn_context_thread``)
        is the one actually invoked."""
        self._generation += 1
        generation = self._generation
        key = (session_id, query)

        def _run() -> None:
            result = run_search(query)
            with self._lock:
                if generation == self._generation:
                    self._entries[key] = result

        thread = spawn_thread(_run, name="robot-notes-prefetch")
        self.thread = thread
        thread.start()

    def clear(self) -> None:
        """Bumps the generation and drops every cached entry, for every session — not
        just one. Used on a session switch/reset, where a search queued before the
        switch (for the outgoing session, or another one sharing this provider
        instance) must not be allowed to land in the cache and get injected afterwards."""
        self._generation += 1
        with self._lock:
            self._entries.clear()

    def consume(self, session_id: str, query: str) -> Optional[SearchResult]:
        """Pop and return the entry cached for this exact ``(session_id, query)`` pair,
        or ``None`` when there isn't one — never queued, a different query, a different
        session, or the background search hasn't landed yet. A miss means the caller
        falls back to a synchronous search, same as before this cache existed."""
        with self._lock:
            return self._entries.pop((session_id, query), None)

    def note_result(self, formatted: str, count: int) -> str:
        """Records the outcome of the most recent :meth:`~RobotNotesProvider.prefetch`
        call for :meth:`status`, and returns ``formatted`` unchanged so callers can wrap
        their return statement with this. An empty ``formatted`` means nothing was
        injected, which :meth:`status` reports as ``None`` rather than a zero count."""
        self._last_count = count if formatted else None
        return formatted

    def status(self, provider_label: str) -> Optional[RecallStatus]:
        if self._last_count is None:
            return None
        return RecallStatus(provider_label, self._last_count)
