"""Configuration for the robot-notes memory provider: non-secret fields live in
``$HERMES_HOME/robot_notes.json``; the API key stays in the environment only."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from ._hermes_compat import get_secret

CONFIG_FILENAME = "robot_notes.json"
API_KEY_ENV_VAR = "ROBOT_NOTES_API_KEY"
DEFAULT_ACTOR = "hermes"
DEFAULT_VAULT_ID = "default"


def _default_hermes_home() -> str:
    return os.environ.get("HERMES_HOME", str(Path.home() / ".hermes"))


@dataclass(frozen=True)
class RobotNotesConfig:
    base_url: str = ""
    actor: str = DEFAULT_ACTOR
    api_key: str = ""
    native_tools: bool = True
    durable_writes: bool = False
    vault_id: str = DEFAULT_VAULT_ID
    memory_scope: str = "shared"
    user_id: str = ""
    agent_id: str = ""
    shared_memory_path: str = ""

    @property
    def memory_note(self) -> dict:
        path = f"Hermes/agents/{self.agent_id}" if self.memory_scope == "identity" else "Hermes"
        return {"path": path, "title": "Memory"}

    @property
    def user_note(self) -> dict:
        path = f"Hermes/users/{self.user_id}" if self.memory_scope == "identity" else "Hermes"
        return {"path": path, "title": "User"}

    @property
    def recall_paths(self) -> tuple[Optional[str], ...]:
        if self.memory_scope == "shared":
            return (None,)
        paths = [self.user_note["path"], self.memory_note["path"]]
        if self.shared_memory_path:
            paths.append(self.shared_memory_path)
        return tuple(dict.fromkeys(paths))

    @property
    def missing_reason(self) -> Optional[str]:
        if not self.base_url:
            return "robot-notes base_url is not configured"
        if not self.api_key:
            return f"{API_KEY_ENV_VAR} is not set"
        return None

    @property
    def is_complete(self) -> bool:
        return self.missing_reason is None

    @classmethod
    def create(
        cls, *, base_url: str = "", actor: str = "", api_key: str = "",
        native_tools: bool = True, durable_writes: bool = False, vault_id: str = DEFAULT_VAULT_ID,
        memory_scope: str = "shared", user_id: str = "", agent_id: str = "",
        shared_memory_path: str = "",
    ) -> "RobotNotesConfig":
        """The one place ``base_url`` is normalized (trailing slash stripped) and
        ``actor`` and ``vault_id`` defaulted — every constructor path (``load()``, the setup wizard's
        ``save_config()``) should go through this rather than repeating either rule."""
        if not isinstance(native_tools, bool):
            raise ValueError("native_tools must be a JSON boolean")
        if not isinstance(durable_writes, bool):
            raise ValueError("durable_writes must be a JSON boolean")
        if memory_scope not in ("shared", "identity"):
            raise ValueError("memory_scope must be shared or identity")
        if memory_scope == "identity":
            for name, identity in (("user_id", user_id), ("agent_id", agent_id)):
                if not isinstance(identity, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", identity):
                    raise ValueError(f"{name} must contain 1-64 lowercase ASCII letters, digits, underscores or hyphens, starting with a letter or digit")
        if not isinstance(shared_memory_path, str) or (
            shared_memory_path and (
                any(part in ("", ".", "..") for part in shared_memory_path.split("/"))
                or "\\" in shared_memory_path
                or any(ord(char) < 32 for char in shared_memory_path)
            )
        ):
            raise ValueError("shared_memory_path must be a relative folder without empty or dot segments")
        return cls(
            base_url=base_url.rstrip("/"), actor=actor or DEFAULT_ACTOR,
            api_key=api_key, native_tools=native_tools, durable_writes=durable_writes, vault_id=vault_id.strip() or DEFAULT_VAULT_ID,
            memory_scope=memory_scope, user_id=user_id, agent_id=agent_id,
            shared_memory_path=shared_memory_path,
        )

    @classmethod
    def load(cls, hermes_home: Optional[str] = None) -> "RobotNotesConfig":
        home = Path(hermes_home or _default_hermes_home())
        path = home / CONFIG_FILENAME
        data: dict = {}
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                data = {}
        return cls.create(
            base_url=str(data.get("base_url", "")),
            actor=str(data.get("actor") or ""),
            api_key=get_secret(API_KEY_ENV_VAR, ""),
            durable_writes=data.get("durable_writes", False),
            native_tools=data.get("native_tools", True),
            vault_id=str(data.get("vault_id") or DEFAULT_VAULT_ID),
            memory_scope=data.get("memory_scope", "shared"),
            user_id=data.get("user_id", ""),
            agent_id=data.get("agent_id", ""),
            shared_memory_path=data.get("shared_memory_path", ""),
        )

    def save(self, hermes_home: str) -> None:
        home = Path(hermes_home)
        home.mkdir(parents=True, exist_ok=True)
        path = home / CONFIG_FILENAME
        payload = {"base_url": self.base_url, "actor": self.actor, "vault_id": self.vault_id}
        if self.durable_writes:
            payload["durable_writes"] = True
        if self.memory_scope != "shared":
            payload.update(memory_scope=self.memory_scope, user_id=self.user_id, agent_id=self.agent_id)
        if self.shared_memory_path:
            payload["shared_memory_path"] = self.shared_memory_path
        if not self.native_tools:
            payload["native_tools"] = False
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
