from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Callable


class QueueFull(Exception):
    """The bounded queue cannot accept another durable operation."""


class Outbox:
    """Persist ordered operations; callers must make replayed effects idempotent."""

    def __init__(self, path: Path, *, max_operations: int = 1000,
                 max_bytes: int = 2 * 1024 * 1024, retention_seconds: float = 30 * 86400,
                 clock: Callable[[], float] = time.time):
        self.path = path
        self.max_operations = max_operations
        self.max_bytes = max_bytes
        self.retention_seconds = retention_seconds
        self.clock = clock
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with closing(self._connect()) as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS operations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL,
                    expires REAL NOT NULL, blocked INTEGER NOT NULL DEFAULT 0,
                    reason TEXT
                );
                CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
                INSERT OR IGNORE INTO counters VALUES ('expired', 0);
            ''')
        os.chmod(path, 0o600)
        self.delivery_path = path.with_suffix('.delivery.sqlite')
        with closing(sqlite3.connect(self.delivery_path)) as db:
            db.execute('CREATE TABLE IF NOT EXISTS worker (id INTEGER PRIMARY KEY)')
        os.chmod(self.delivery_path, 0o600)

    def _connect(self):
        return sqlite3.connect(self.path, timeout=1)

    def _expire(self, db):
        count = db.execute('SELECT COUNT(*) FROM operations WHERE expires <= ?', (self.clock(),)).fetchone()[0]
        db.execute('DELETE FROM operations WHERE expires <= ?', (self.clock(),))
        db.execute("UPDATE counters SET value = value + ? WHERE name = 'expired'", (count,))

    def enqueue(self, operation: dict) -> None:
        payload = json.dumps(operation, ensure_ascii=False, separators=(',', ':'))
        with closing(self._connect()) as db:
            db.execute('BEGIN IMMEDIATE')
            self._expire(db)
            count, size = db.execute('SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(payload AS BLOB))), 0) FROM operations').fetchone()
            if count >= self.max_operations or size + len(payload.encode('utf-8')) > self.max_bytes:
                raise QueueFull('Automatic memory queue capacity exceeded')
            db.execute('INSERT INTO operations(payload, expires) VALUES (?, ?)', (payload, self.clock() + self.retention_seconds))
            db.commit()

    def deliver_one(self, deliver: Callable[[dict], None], classify=None, prepare=None) -> bool:
        """Deliver one operation; a separate process-safe lock permits concurrent enqueue."""
        with closing(sqlite3.connect(self.delivery_path, timeout=0)) as worker:
            try:
                worker.execute('BEGIN IMMEDIATE')
            except sqlite3.OperationalError as exc:
                if 'locked' in str(exc):
                    return False
                raise
            with closing(self._connect()) as db:
                db.execute('BEGIN IMMEDIATE')
                self._expire(db)
                row = db.execute('SELECT id, payload, blocked FROM operations ORDER BY id LIMIT 1').fetchone()
                db.commit()
                if row is None or row[2]:
                    return False
                operation = json.loads(row[1])
                try:
                    if prepare and "prepared" not in operation:
                        operation = prepare(operation)
                        payload = json.dumps(operation, ensure_ascii=False, separators=(',', ':'))
                        db.execute('BEGIN IMMEDIATE')
                        size = db.execute('SELECT COALESCE(SUM(LENGTH(CAST(payload AS BLOB))), 0) FROM operations WHERE id != ?', (row[0],)).fetchone()[0]
                        if size + len(payload.encode('utf-8')) > self.max_bytes:
                            db.rollback()
                            raise QueueFull('Prepared effect exceeds queue capacity')
                        db.execute('UPDATE operations SET payload = ? WHERE id = ?', (payload, row[0]))
                        db.commit()
                    deliver(operation)
                except Exception as exc:
                    reason, retryable = classify(exc) if classify else ('delivery_error', True)
                    db.execute('UPDATE operations SET reason = ?, blocked = ? WHERE id = ?', (reason, not retryable, row[0]))
                    db.commit()
                    return False
                db.execute('DELETE FROM operations WHERE id = ?', (row[0],))
                db.commit()
                return True

    def retry_blocked(self) -> None:
        """Explicitly permit another attempt after a permanent failure was corrected."""
        with closing(self._connect()) as db:
            db.execute('UPDATE operations SET blocked = 0')
            db.commit()

    def status(self) -> dict:
        with closing(self._connect()) as db:
            row = db.execute('SELECT blocked, reason FROM operations ORDER BY id LIMIT 1').fetchone()
            return {
                'pending': db.execute('SELECT COUNT(*) FROM operations').fetchone()[0],
                'blocked': bool(row and row[0]),
                **({'reason': row[1]} if row and row[1] else {}),
                'expired': db.execute("SELECT value FROM counters WHERE name = 'expired'").fetchone()[0],
            }
