"""Configuration for the robot-notes memory provider: non-secret fields live in
``$HERMES_HOME/robot_notes.json``; the API key stays in the environment only."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

CONFIG_FILENAME = "robot_notes.json"
API_KEY_ENV_VAR = "ROBOT_NOTES_API_KEY"
DEFAULT_ACTOR = "hermes"


def _default_hermes_home() -> str:
    return os.environ.get("HERMES_HOME", str(Path.home() / ".hermes"))


@dataclass(frozen=True)
class RobotNotesConfig:
    base_url: str = ""
    actor: str = DEFAULT_ACTOR
    api_key: str = ""

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
    def create(cls, *, base_url: str = "", actor: str = "", api_key: str = "") -> "RobotNotesConfig":
        """The one place ``base_url`` is normalized (trailing slash stripped) and
        ``actor`` defaulted — every constructor path (``load()``, the setup wizard's
        ``save_config()``) should go through this rather than repeating either rule."""
        return cls(base_url=base_url.rstrip("/"), actor=actor or DEFAULT_ACTOR, api_key=api_key)

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
            api_key=os.environ.get(API_KEY_ENV_VAR, ""),
        )

    def save(self, hermes_home: str) -> None:
        home = Path(hermes_home)
        home.mkdir(parents=True, exist_ok=True)
        path = home / CONFIG_FILENAME
        payload = {"base_url": self.base_url, "actor": self.actor}
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
