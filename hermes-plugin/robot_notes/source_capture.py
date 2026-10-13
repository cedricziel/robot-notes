from __future__ import annotations

import base64
import hashlib
import json
import sqlite3
import threading
import uuid
from pathlib import Path

from ._hermes_compat import spawn_context_thread
from .client import ClientError, ErrorKind, RobotNotesClient
from .outbox import Outbox, QueueFull


class SourceCapture:
    """Durable opt-in observations; server scope controls extraction eligibility."""

    def __init__(self, config, home: Path):
        self.config = config
        destination = hashlib.sha256(json.dumps({key: getattr(config, key) for key in
            ("base_url", "vault_id", "api_key", "source_scope_id")}, sort_keys=True).encode()).hexdigest()
        self.outbox = Outbox(home / "robot_notes_sources" / destination / "queue.sqlite",
                             max_bytes=16 * 1024 * 1024, secure_delete=True)
        self._client = RobotNotesClient(base_url=config.base_url, api_key=config.api_key,
                                       actor=config.actor, vault_id=config.vault_id)
        self._lock = threading.Lock()
        self._thread = None
        self._stopped = False
        self._state = {"state": "not_attempted"}

    def enqueue(self, session_id: str, kind: str, messages: list, *, event_id: str = "") -> None:
        if self._stopped or not session_id:
            return
        try:
            payload = json.dumps({"session_id": session_id, "messages": messages},
                                 ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
            operation = {"adapter": "hermes", "event_id": event_id or str(uuid.uuid4()),
                         "scope_id": self.config.source_scope_id, "content_base64": base64.b64encode(payload).decode("ascii"),
                         "media_type": "application/json", "automatic": True,
                         "observation_kind": kind, "conversation_id": session_id}
            self.outbox.enqueue(operation, idempotency_key=operation["event_id"])
            self._state = {"state": "queued"}
        except (TypeError, ValueError, QueueFull, OSError, sqlite3.Error) as exc:
            self._state = {"state": "failed", "reason": "queue_full" if isinstance(exc, QueueFull) else "capture_failed"}
            return
        self.start()

    def _send(self, operation):
        if self._stopped:
            raise RuntimeError("Capture stopped")
        capabilities = self._client.knowledge_capabilities()
        self._client.ingest_source(operation, expected_principal_id=capabilities.get("principal_id"))
        self._state = {"state": "delivered"}

    @staticmethod
    def _classify(error):
        if isinstance(error, ClientError):
            retry = (error.kind in (ErrorKind.NETWORK_ERROR, ErrorKind.CIRCUIT_OPEN) or (error.status is not None and error.status >= 500 and error.code != "unsupported_capability"))
            return error.code or error.kind.name.lower(), retry
        return "delivery_failed", False

    def flush(self, *, retry_blocked: bool = False):
        if self._stopped or not self._lock.acquire(blocking=False):
            return
        try:
            if retry_blocked:
                self.outbox.retry_blocked()
            while not self._stopped and self.outbox.deliver_one(self._send, classify=self._classify):
                pass
        finally:
            self._lock.release()

    def start(self):
        if self._stopped or (self._thread and self._thread.is_alive()):
            return
        self._thread = spawn_context_thread(self.flush, name="robot-notes-source-capture")
        self._thread.start()

    def status(self):
        queue = self.outbox.status()
        return {**self._state, **({"state": "blocked", "reason": queue.get("reason")} if queue["blocked"] else {}), "queue": queue}

    def stop(self):
        self._stopped = True
        if self._thread:
            self._thread.join(timeout=10)
        self._client.close()
