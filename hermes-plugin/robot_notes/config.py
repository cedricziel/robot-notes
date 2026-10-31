"""Configuration for the robot-notes memory provider: non-secret fields live in
``$HERMES_HOME/robot_notes.json``; the API key stays in the environment only."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

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
    source_capture: bool = False
    source_scope_id: str = ""
    evidence_archive: bool = False
    evidence_retention_days: int = 30
    native_tools: bool = True
    durable_writes: bool = False
    vault_id: str = DEFAULT_VAULT_ID
    memory_scope: str = "shared"
    user_id: str = ""
    agent_id: str = ""
    shared_memory_path: str = ""
    recall_path: Optional[str] = None
    recall_max_bytes: int = 0
    recall_expand_chars: int = 0
    upload_roots: tuple[str, ...] = ()

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
        evidence_archive: bool = False, evidence_retention_days: int = 30,
        source_capture: bool = False, source_scope_id: str = "",
        recall_path: Optional[str] = None, recall_max_bytes: int = 0, recall_expand_chars: int = 0,
        upload_roots: Sequence[str] = (),
    ) -> "RobotNotesConfig":
        """The one place ``base_url`` is normalized (trailing slash stripped) and
        ``actor`` and ``vault_id`` defaulted — every constructor path (``load()``, the setup wizard's
        ``save_config()``) should go through this rather than repeating either rule."""
        if type(source_capture) is not bool:
            raise ValueError("source_capture must be a JSON boolean")
        if not isinstance(source_scope_id, str) or (source_capture and not source_scope_id.strip()):
            raise ValueError("source_capture requires a configured source_scope_id")
        if not isinstance(evidence_archive, bool):
            raise ValueError("evidence_archive must be a JSON boolean")
        if type(evidence_retention_days) is not int or not 1 <= evidence_retention_days <= 3650:
            raise ValueError("evidence_retention_days must be an integer between 1 and 3650")
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
        if recall_path is not None and (
            not isinstance(recall_path, str) or not recall_path
            or any(part in ("", ".", "..") for part in recall_path.split("/"))
            or "\\" in recall_path or any(ord(char) < 32 for char in recall_path)
        ):
            raise ValueError("recall_path must be a relative folder without empty or dot segments")
        for name, value, maximum in (("recall_max_bytes", recall_max_bytes, 65536), ("recall_expand_chars", recall_expand_chars, 8192)):
            if type(value) is not int or not 0 <= value <= maximum:
                raise ValueError(f"{name} must be an integer between 0 and {maximum}")
        if recall_expand_chars and not recall_max_bytes:
            raise ValueError("recall_expand_chars requires recall_max_bytes")
        if isinstance(upload_roots, str) or not all(
            isinstance(root, str) and os.path.isabs(root) for root in upload_roots
        ):
            raise ValueError("upload_roots must be a list of absolute directory paths")
        return cls(
            source_capture=source_capture, source_scope_id=source_scope_id,
            evidence_archive=evidence_archive, evidence_retention_days=evidence_retention_days,
            base_url=base_url.rstrip("/"), actor=actor or DEFAULT_ACTOR,
            api_key=api_key, native_tools=native_tools, durable_writes=durable_writes, vault_id=vault_id.strip() or DEFAULT_VAULT_ID,
            memory_scope=memory_scope, user_id=user_id, agent_id=agent_id,
            shared_memory_path=shared_memory_path, recall_path=recall_path,
            recall_max_bytes=recall_max_bytes, recall_expand_chars=recall_expand_chars,
            upload_roots=tuple(upload_roots),
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
            source_capture=data.get("source_capture", False),
            source_scope_id=data.get("source_scope_id", ""),
            evidence_archive=data.get("evidence_archive", False),
            evidence_retention_days=data.get("evidence_retention_days", 30),
            native_tools=data.get("native_tools", True),
            vault_id=str(data.get("vault_id") or DEFAULT_VAULT_ID),
            memory_scope=data.get("memory_scope", "shared"),
            user_id=data.get("user_id", ""),
            agent_id=data.get("agent_id", ""),
            shared_memory_path=data.get("shared_memory_path", ""),
            recall_path=data.get("recall_path"),
            recall_max_bytes=data.get("recall_max_bytes", 0),
            recall_expand_chars=data.get("recall_expand_chars", 0),
            upload_roots=data.get("upload_roots", ()),
        )

    def save(self, hermes_home: str) -> None:
        home = Path(hermes_home)
        home.mkdir(parents=True, exist_ok=True)
        path = home / CONFIG_FILENAME
        payload = {"base_url": self.base_url, "actor": self.actor, "vault_id": self.vault_id}
        if self.source_capture:
            payload.update(source_capture=True, source_scope_id=self.source_scope_id)
        if self.durable_writes:
            payload["durable_writes"] = True
        if self.memory_scope != "shared":
            payload.update(memory_scope=self.memory_scope, user_id=self.user_id, agent_id=self.agent_id)
        if self.shared_memory_path:
            payload["shared_memory_path"] = self.shared_memory_path
        if self.evidence_archive:
            payload["evidence_archive"] = True
        if self.evidence_retention_days != 30:
            payload["evidence_retention_days"] = self.evidence_retention_days
        if self.recall_path is not None:
            payload["recall_path"] = self.recall_path
        if self.recall_max_bytes:
            payload["recall_max_bytes"] = self.recall_max_bytes
        if self.recall_expand_chars:
            payload["recall_expand_chars"] = self.recall_expand_chars
        if self.upload_roots:
            payload["upload_roots"] = list(self.upload_roots)
        if not self.native_tools:
            payload["native_tools"] = False
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
