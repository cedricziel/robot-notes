"""``MemoryProvider`` ABC: the real one from ``hermes-agent``'s ``agent.memory_provider``
when this plugin runs inside a Hermes process, else ``_LocalMemoryProvider`` below --
a local copy of the same abstract surface, kept so this package's own test suite can
run without a hermes-agent checkout on the path.

``_LocalMemoryProvider`` is always defined (not only when the upstream import fails)
so ``tests/test_stub_parity.py`` can compare it against the real ABC even when
hermes-agent *is* importable; only the public ``MemoryProvider`` name picks upstream
first.

Known drift risk: ``hermes-agent`` is a CLI application, not a package published for
installation as a library, so there is no dependency to pin here and no automated
check in normal CI runs. ``tests/test_stub_parity.py`` closes part of that gap when
run with ``agent.memory_provider`` on ``PYTHONPATH`` (skipped otherwise) -- re-run it
after upgrading against a new hermes-agent release, or re-check this file by hand
against the upstream source.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Any, Dict, List, Optional

# NOTE: ``RecallStatus`` is referenced only in a return annotation below and, thanks to
# ``from __future__ import annotations`` (PEP 563), annotations are never evaluated at
# runtime -- so this forward reference resolves fine without importing the real type here.
# The importable ``RecallStatus`` lives in ``_hermes_compat`` alongside its own
# upstream-first import / fallback, matching where the other module-level helpers live.
if TYPE_CHECKING:  # pragma: no cover - for type checkers only, never executed
    from ._hermes_compat import RecallStatus


class _LocalMemoryProvider(ABC):
    """Local stand-in for ``agent.memory_provider.MemoryProvider``. Method set, signatures
    and defaults are kept in sync with upstream by hand; see the module docstring."""

    # Providers that durably checkpoint every successful on_pre_compress() set this to 2;
    # 1 (default) = best-effort legacy.
    pre_compress_checkpoint_api_version = 1

    @property
    @abstractmethod
    def name(self) -> str:
        """Short identifier for this provider (e.g. 'builtin', 'honcho', 'hindsight')."""

    # -- Core lifecycle (implement these) ------------------------------------

    @abstractmethod
    def is_available(self) -> bool:
        """Configured, credentialed and ready? Gates activation; check config/deps only, no network."""

    @abstractmethod
    def initialize(self, session_id: str, **kwargs) -> None:
        """Initialize once at agent startup (connections, resources, threads)."""

    def unavailable_reason(self) -> str:
        """User-facing hint for the "provider unavailable" warning."""
        return ""

    def system_prompt_block(self) -> str:
        """STATIC system-prompt text; "" to skip."""
        return ""

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        """Formatted recall context for the upcoming turn ("" if none)."""
        return ""

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Queue a background recall after each turn; prefetch() consumes it next turn."""
        return None

    def recall_status(self) -> Optional[RecallStatus]:
        """What the most recent :meth:`prefetch` injected (``None`` = no indicator)."""
        return None

    def sync_turn(
        self,
        user_content: str,
        assistant_content: str,
        *,
        session_id: str = "",
        messages: Optional[List[Dict[str, Any]]] = None,
        turn_author: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Persist a completed turn (non-blocking)."""
        return None

    @abstractmethod
    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        """OpenAI function-calling schemas ({"name", "description", "parameters"}); [] if none."""

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        """Handle one of this provider's tools; must return a JSON string."""
        raise NotImplementedError(f"Provider {self.name} does not handle tool {tool_name}")

    def shutdown(self) -> None:
        """Clean shutdown -- flush queues, close connections."""
        return None

    # -- Optional hooks (override to opt in) ---------------------------------

    def on_turn_start(self, turn_number: int, message: str, **kwargs) -> None:
        """Per-turn tick."""
        return None

    def identity_signature(self) -> Dict[str, Any]:
        """Identity-mapping values that must bust a cached gateway agent when they change."""
        return {}

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        """End-of-session extraction; fires only at real session boundaries, never per-turn."""
        return None

    def on_session_switch(
        self,
        new_session_id: str,
        *,
        parent_session_id: str = "",
        reset: bool = False,
        rewound: bool = False,
        **kwargs,
    ) -> None:
        """session_id reassigned mid-process (/resume, /branch, /reset, /new, compression) without
        teardown: rebind per-session state so later writes land in the right record."""
        return None

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        """Extract insights from ``messages`` about to be compressed, fed into the summary prompt."""
        return ""

    def on_delegation(self, task: str, result: str, *, child_session_id: str = "", **kwargs) -> None:
        """PARENT-side observation of a completed delegation."""
        return None

    def get_config_schema(self) -> List[Dict[str, Any]]:
        """Setup fields for ``hermes memory setup`` ([] if none)."""
        return []

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        """Write non-secret setup ``values`` to the provider's native config."""
        return None

    def on_memory_write(
        self, action: str, target: str, content: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        """Mirror a built-in memory-tool write (action: add | replace | remove; target: memory | user)."""
        return None

    def backup_paths(self) -> List[str]:
        """Absolute paths of provider state OUTSIDE HERMES_HOME for ``hermes backup``/``import``."""
        return []


try:
    from agent.memory_provider import MemoryProvider  # type: ignore
except ImportError:
    MemoryProvider = _LocalMemoryProvider  # type: ignore[misc,assignment]
