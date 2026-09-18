"""``MemoryProvider`` base class: the real one from ``hermes-agent``'s ``agent``
package when this plugin runs inside a Hermes process, else a local stub
exposing the same abstract surface — used only so this package's own test
suite can run without a hermes-agent checkout on the path.

Known drift risk: ``hermes-agent`` is a CLI application, not a package
published for installation as a library, so there is no dependency to pin
here and no automated check that this stub still matches the real ABC. If
``hermes-agent`` changes ``agent.memory_provider.MemoryProvider``'s method
set or signatures, this stub — and this package's test suite, which only
ever exercises the stub — will not notice. Re-check this file by hand
against the upstream source after upgrading the plugin for a new
hermes-agent release."""

from __future__ import annotations

try:
    from agent.memory_provider import MemoryProvider  # type: ignore
except ImportError:
    from abc import ABC, abstractmethod
    from typing import Any, Dict, List, Optional

    class MemoryProvider(ABC):  # type: ignore[no-redef]
        @property
        @abstractmethod
        def name(self) -> str: ...

        @abstractmethod
        def is_available(self) -> bool: ...

        @abstractmethod
        def initialize(self, session_id: str, **kwargs) -> None: ...

        @abstractmethod
        def get_tool_schemas(self) -> List[Dict[str, Any]]: ...

        def unavailable_reason(self) -> str:
            return ""

        def system_prompt_block(self) -> str:
            return ""

        def prefetch(self, query: str, *, session_id: str = "") -> str:
            return ""

        def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
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
            return None

        def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
            raise NotImplementedError(f"Provider {self.name} does not handle tool {tool_name}")

        def shutdown(self) -> None:
            return None

        def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
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
            return None

        def on_memory_write(
            self, action: str, target: str, content: str, metadata: Optional[Dict[str, Any]] = None
        ) -> None:
            return None

        def get_config_schema(self) -> List[Dict[str, Any]]:
            return []

        def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
            return None

        def backup_paths(self) -> List[str]:
            return []
