"""Host-compat shim: everything this plugin borrows from a running Hermes process,
each with an upstream-first import and a local fallback so the plugin -- and its test
suite -- keeps working outside a hermes-agent checkout.

- ``MemoryProvider``, ``RecallStatus``, ``spawn_context_thread``, ``is_trivial_prompt``
  come from ``agent.memory_provider``.
- ``get_secret`` comes from ``agent.secret_scope`` (as ``get_secret_str``, which already
  has the ``(name, default="") -> str`` shape this plugin wants).
- ``tool_error`` comes from ``tools.registry``.

Each symbol falls back independently: e.g. a hermes-agent checkout old enough to lack
one helper, or a partial checkout where only ``agent.memory_provider`` is on
``PYTHONPATH``, still gets working fallbacks for the rest rather than an ImportError.
"""

from __future__ import annotations

import contextvars
import json
import os
import re
import threading
from dataclasses import dataclass
from typing import Any, Callable, Dict, Optional

from ._memory_provider_base import MemoryProvider

__all__ = [
    "MemoryProvider",
    "RecallStatus",
    "spawn_context_thread",
    "is_trivial_prompt",
    "get_secret",
    "tool_error",
]


try:
    from agent.memory_provider import (  # type: ignore
        RecallStatus,
        is_trivial_prompt,
        spawn_context_thread,
    )
except ImportError:
    # Default glyph for recall indicators; providers may use their own brand mark.
    _INDICATOR_GLYPH = "\U0001f9e0"  # "🧠"

    @dataclass(frozen=True)
    class RecallStatus:  # type: ignore[no-redef]
        """What the last prefetch injected, for a deterministic recall indicator.
        ``count == 0`` means content without a discrete count."""

        provider_label: str
        count: int
        glyph: str = _INDICATOR_GLYPH

    def _ctx_bound(fn: Callable[..., Any]) -> Callable[..., Any]:
        """Bind ``fn`` to the caller's contextvars so it still sees them on another thread."""
        ctx = contextvars.copy_context()
        return lambda *args, **kwargs: ctx.run(fn, *args, **kwargs)

    def spawn_context_thread(  # type: ignore[no-redef]
        target: Callable[..., Any],
        *,
        name: str,
        daemon: bool = True,
        args: tuple = (),
        kwargs: Optional[Dict[str, Any]] = None,
    ) -> threading.Thread:
        """Unstarted thread running *target* under the spawner's contextvars."""
        return threading.Thread(target=_ctx_bound(target), args=args, kwargs=kwargs, name=name, daemon=daemon)

    # Prompts with no semantic signal; anchored and followed only by whitespace/punctuation.
    _TRIVIAL_PROMPT_RE = re.compile(
        r'^(yes|no|ok|okay|sure|thanks|thank you|y|n|yep|nope|yeah|nah|'
        r'hi|hey|hello|yo|sup|'
        r'continue|go ahead|do it|proceed|got it|cool|nice|great|done|next|lgtm|k)'
        r'[\s!?.:;,"' + "'" + r'~‘’“”—–…()\[\]{}<>*&^%$#@!+=` ]*$',
        re.IGNORECASE,
    )

    def is_trivial_prompt(text: Optional[str]) -> bool:  # type: ignore[no-redef]
        """True for empty input, slash commands and bare greetings/acknowledgements."""
        stripped = (text or "").strip()
        if not stripped or stripped.startswith("/"):
            return True
        return bool(_TRIVIAL_PROMPT_RE.match(stripped))


try:
    from agent.secret_scope import get_secret_str as get_secret  # type: ignore
except ImportError:

    def get_secret(name: str, default: str = "") -> str:
        """Fallback: read straight from the process environment (no profile scoping)."""
        return os.environ.get(name, default)


try:
    from tools.registry import tool_error  # type: ignore
except ImportError:

    def tool_error(message: Any) -> str:
        """Fallback: ``'{"error": "<message>"}'`` with none of upstream's length bounding."""
        return json.dumps({"error": str(message)})
