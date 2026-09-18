#!/usr/bin/env python3
"""Claude Code hook: appends this session's prompts and assistant replies to a
robot-notes note at conversations/<actor>/<session_id>, one line per
UserPromptSubmit or Stop event.

Opt-in and best-effort: no-ops silently when ROBOT_NOTES_BASE_URL /
ROBOT_NOTES_API_KEY aren't set, and never raises or blocks the interactive
turn on a network failure. The actual HTTP calls run in a detached background
process (spawned by `main`, selected here via `--worker`) so a slow or
unreachable robot-notes server adds no latency to the hook itself.

A per-session file lock (`_acquire_session_lock`/`_release_session_lock`)
serializes the two events' detached workers: without it, the UserPromptSubmit
and Stop workers for the same turn could race to create the session's note
(one loses with a path conflict that's silently dropped) or write out of
order (Stop's worker finishing before UserPromptSubmit's). The lock is
acquired in the background worker, never in the foreground hook, so a slow
or unreachable server still never delays the interactive turn.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

CONVERSATIONS_ROOT = "conversations"
DEFAULT_ACTOR = "claude-code"
MAX_RETRIES = 3
REQUEST_TIMEOUT = 8

LOCK_DIR = os.path.join(tempfile.gettempdir(), "robot-notes-conversation-locks")
LOCK_WAIT_TIMEOUT = 30
LOCK_STALE_SECONDS = 60


def sanitize_actor(actor: str) -> str:
    """Collapses an actor value to exactly one safe path segment: flattens any
    '/' (so a misconfigured actor can't nest extra folders) and falls back to
    DEFAULT_ACTOR for anything that would resolve to a no-op or traversal
    segment ("", ".", "..")."""
    cleaned = actor.replace("/", "_").strip()
    return cleaned if cleaned and cleaned not in (".", "..") else DEFAULT_ACTOR


def conversations_path(actor: str) -> str:
    return f"{CONVERSATIONS_ROOT}/{sanitize_actor(actor)}"


class VersionConflict(Exception):
    pass


def _request(
    base_url: str,
    api_key: str,
    actor: str,
    method: str,
    path: str,
    body: Optional[Dict[str, Any]] = None,
    extra_headers: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    headers = {"Authorization": f"Bearer {api_key}", "X-Actor": actor}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(f"{base_url}{path}", data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def find_note_by_title(base_url: str, api_key: str, actor: str, title: str, path: str) -> Optional[Dict[str, Any]]:
    """Looks up a note by exact title within path. Tries the server's dedicated
    title filter first (a single request); an older server that doesn't
    support it answers with HTTP 400, which is treated as "unsupported" and
    falls back to a full cursor scan of the folder instead of being raised.
    Any other error from the filter attempt (network failure, 5xx, etc.) is
    not swallowed."""
    query = urllib.parse.urlencode({"path": path, "title": title, "limit": 1})
    try:
        result = _request(base_url, api_key, actor, "GET", f"/notes?{query}")
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            raise
    else:
        items = result.get("items", [])
        return items[0] if items else None
    return _find_note_by_title_scan(base_url, api_key, actor, title, path)


def _find_note_by_title_scan(base_url: str, api_key: str, actor: str, title: str, path: str) -> Optional[Dict[str, Any]]:
    """Scans every page of path's notes for title — the session's note can land
    past the first 200 once a folder holds more, and missing it here would send
    append_line down the create path straight into a path conflict with the
    note that's actually already there. Used only when the server has no
    title filter to lean on (find_note_by_title's 400 fallback)."""
    cursor: Optional[str] = None
    while True:
        params = {"path": path, "limit": 200}
        if cursor:
            params["after"] = cursor
        query = urllib.parse.urlencode(params)
        result = _request(base_url, api_key, actor, "GET", f"/notes?{query}")
        for item in result.get("items", []):
            if item.get("title") == title:
                return item
        cursor = result.get("next_cursor")
        if not cursor:
            return None


def create_note(base_url: str, api_key: str, actor: str, title: str, content: str, path: str) -> Dict[str, Any]:
    return _request(base_url, api_key, actor, "POST", "/notes", {"title": title, "content": content, "path": path})


def update_note(base_url: str, api_key: str, actor: str, note_id: str, version: int, content: str) -> Dict[str, Any]:
    try:
        return _request(
            base_url,
            api_key,
            actor,
            "PUT",
            f"/notes/{note_id}",
            {"content": content},
            extra_headers={"If-Match": str(version)},
        )
    except urllib.error.HTTPError as exc:
        if exc.code == 409:
            raise VersionConflict() from exc
        raise


def append_note(base_url: str, api_key: str, actor: str, note_id: str, content: str) -> Dict[str, Any]:
    return _request(base_url, api_key, actor, "POST", f"/notes/{note_id}/append", {"content": content})


def _join_with_separator(current: str, addition: str) -> str:
    """Joins current+addition the same way the server's
    POST /notes/{id}/append does (NoteWriteService.append): empty current
    becomes exactly addition; otherwise a single "\\n" separator is inserted
    only when current doesn't already end with one, so a note ending on a
    blank line doesn't grow an extra one on every append."""
    if not current:
        return addition
    return current + ("" if current.endswith("\n") else "\n") + addition


def append_line(base_url: str, api_key: str, actor: str, title: str, path: str, line: str) -> None:
    note = find_note_by_title(base_url, api_key, actor, title, path)
    if note is None:
        create_note(base_url, api_key, actor, title, line, path)
        return
    try:
        append_note(base_url, api_key, actor, note["id"], line)
        return
    except urllib.error.HTTPError as exc:
        if exc.code not in (404, 405):
            raise
    # The server predates POST /notes/{id}/append (404/405 on the route);
    # fall back to a client-side read-modify-write retry loop.
    _append_line_fallback(base_url, api_key, actor, note["id"], line)


def _append_line_fallback(base_url: str, api_key: str, actor: str, note_id: str, line: str) -> None:
    for _ in range(MAX_RETRIES):
        current = _request(base_url, api_key, actor, "GET", f"/notes/{note_id}")
        existing = current.get("content", "")
        content = _join_with_separator(existing, line)
        try:
            update_note(base_url, api_key, actor, note_id, current["version"], content)
            return
        except VersionConflict:
            continue


def format_line(payload: Dict[str, Any]) -> Optional[str]:
    event = payload.get("hook_event_name", "")
    if event == "UserPromptSubmit":
        text = payload.get("prompt", "")
        return f"**user**: {text}" if text.strip() else None
    if event == "Stop":
        text = payload.get("last_assistant_message", "")
        return f"**assistant**: {text}" if text.strip() else None
    return None


def _session_lock_path(session_id: str) -> str:
    safe = session_id.replace(os.sep, "_").replace("/", "_")
    return os.path.join(LOCK_DIR, f"{safe}.lock")


def acquire_session_lock(
    session_id: str, timeout: float = LOCK_WAIT_TIMEOUT, stale_seconds: float = LOCK_STALE_SECONDS
) -> str:
    """Cross-platform, stdlib-only mutual exclusion per session id, via an
    atomically created lock file (O_CREAT|O_EXCL) rather than fcntl/msvcrt, so
    it works unchanged on POSIX and Windows. A lock file older than
    stale_seconds is treated as abandoned (its owning worker died without
    releasing it) and reclaimed rather than blocking every future event for
    the session forever."""
    os.makedirs(LOCK_DIR, exist_ok=True)
    lock_path = _session_lock_path(session_id)
    deadline = time.monotonic() + timeout
    while True:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
            return lock_path
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock_path) > stale_seconds:
                    os.remove(lock_path)
                    continue
            except OSError:
                continue  # lock file vanished (released) between the check and here
            if time.monotonic() > deadline:
                raise TimeoutError(f"timed out waiting for conversation lock: {session_id}")
            time.sleep(0.05)


def release_session_lock(lock_path: str) -> None:
    try:
        os.remove(lock_path)
    except OSError:
        pass


def run(payload: Dict[str, Any]) -> None:
    base_url = os.environ.get("ROBOT_NOTES_BASE_URL", "").rstrip("/")
    api_key = os.environ.get("ROBOT_NOTES_API_KEY", "")
    actor = os.environ.get("ROBOT_NOTES_ACTOR", DEFAULT_ACTOR)
    if not base_url or not api_key:
        return

    line = format_line(payload)
    if line is None:
        return

    session_id = payload.get("session_id") or "unknown-session"
    try:
        lock_path = acquire_session_lock(session_id)
    except Exception:
        return  # couldn't get exclusive access in time; skip rather than race

    try:
        append_line(base_url, api_key, actor, session_id, conversations_path(actor), line)
    except Exception:
        pass  # best-effort logging only; never surface a failure here
    finally:
        release_session_lock(lock_path)


def main() -> None:
    if "--worker" in sys.argv:
        payload_path = sys.argv[sys.argv.index("--worker") + 1]
        try:
            with open(payload_path, "r", encoding="utf-8") as f:
                payload = json.load(f)
        finally:
            try:
                os.remove(payload_path)
            except OSError:
                pass
        run(payload)
        return

    if not os.environ.get("ROBOT_NOTES_BASE_URL") or not os.environ.get("ROBOT_NOTES_API_KEY"):
        return

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        return
    if payload.get("hook_event_name") not in ("UserPromptSubmit", "Stop"):
        return

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8") as tmp:
        json.dump(payload, tmp)
        tmp_path = tmp.name

    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--worker", tmp_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
