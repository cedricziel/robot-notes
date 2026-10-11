from __future__ import annotations

import hashlib
import json
import logging
import os
import sqlite3
import threading
from pathlib import Path
from typing import Any, Dict, List

from .client import ClientError, ErrorKind, RobotNotesClient
from .config import RobotNotesConfig
from .outbox import Outbox

logger = logging.getLogger(__name__)


class _ArchiveStopped(RuntimeError):
    pass


class EvidenceArchive:
    """Queue exact JSON snapshots and require remote acknowledgement at checkpoints."""

    def __init__(self, config: RobotNotesConfig, home: Path):
        self.config = config
        identity = {key: getattr(config, key, None) for key in (
            'base_url', 'vault_id', 'actor', 'api_key', 'memory_scope', 'user_id', 'agent_id',
        )}
        destination = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        directory = home / 'robot_notes_outbox' / destination / 'evidence'
        self.outbox = Outbox(directory / 'queue.sqlite', max_bytes=32 * 1024 * 1024,
                             retention_seconds=config.evidence_retention_days * 86400, secure_delete=True)
        self._loss_marker = directory / 'capture_failed'
        self._lock = threading.Lock()
        self._active = True

    def enqueue(self, session_id: str, kind: str, messages: List[Dict[str, Any]],
                capture: str, lineage: dict) -> None:
        try:
            payload = json.dumps({
                'session_id': session_id, 'kind': kind, 'messages': messages, 'capture': capture,
            }, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
            self.outbox.enqueue({
                'id': hashlib.sha256(payload.encode('utf-8')).hexdigest(),
                'payload': payload, 'retention_days': self.config.evidence_retention_days,
                'lineage': lineage,
            })
        except Exception:
            # The marker survives restart even when the raw snapshot could not be queued.
            try:
                with self._loss_marker.open('wb') as marker:
                    os.chmod(self._loss_marker, 0o600)
                    marker.write(b'capture failed\n')
                    marker.flush()
                    os.fsync(marker.fileno())
            except OSError:
                pass
            raise

    def stop(self) -> None:
        self._active = False

    @staticmethod
    def _classify(error):
        if isinstance(error, _ArchiveStopped):
            return 'cancelled', True
        if isinstance(error, ClientError):
            retryable = error.kind in {ErrorKind.NETWORK_ERROR, ErrorKind.CIRCUIT_OPEN} or (error.status or 0) >= 500
            return error.kind.name.lower(), retryable
        return 'delivery_error', False

    def flush(self) -> None:
        """Fail if queued evidence was lost or has not been durably acknowledged."""
        with self._lock:
            if not self._active:
                raise _ArchiveStopped('Conversation evidence delivery stopped')
            status = self.outbox.status()
            if self._loss_marker.exists() or status['expired']:
                raise RuntimeError('Conversation evidence was not retained locally')
            client = RobotNotesClient(base_url=self.config.base_url, api_key=self.config.api_key,
                                      actor=self.config.actor, vault_id=self.config.vault_id)
            try:
                def deliver(operation):
                    if not self._active:
                        raise _ArchiveStopped('Conversation evidence delivery stopped')
                    client.put_evidence(operation['id'], payload=operation['payload'],
                                        retention_days=operation['retention_days'], lineage=operation['lineage'])

                while self.outbox.deliver_one(deliver, self._classify):
                    pass
            except (OSError, sqlite3.Error) as exc:
                raise RuntimeError('Conversation evidence queue unavailable') from exc
            finally:
                client.close()
            status = self.outbox.status()
            if status['pending'] or status['expired'] or self._loss_marker.exists():
                raise RuntimeError('Conversation evidence has not been durably acknowledged')

    def flush_best_effort(self) -> None:
        try:
            self.flush()
        except Exception as exc:
            logger.warning('Evidence archive remains pending: %s', exc)
