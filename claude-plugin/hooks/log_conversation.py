#!/usr/bin/env python3
"""Claude Code hook: appends this session's prompts and assistant replies to a
robot-notes note at conversations/<actor>/<session_id>, one line per
UserPromptSubmit or Stop event.

Opt-in and best-effort: no-ops silently when ROBOT_NOTES_BASE_URL /
ROBOT_NOTES_API_KEY aren't set, and never raises or blocks the interactive
turn on a network failure. The actual HTTP calls run in a detached background
process (spawned by `main`, selected here via `--worker`) so a slow or
unreachable robot-notes server adds no latency to the hook itself.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

CONVERSATIONS_ROOT = "conversations"
MAX_RETRIES = 3
REQUEST_TIMEOUT = 8


def conversations_path(actor: str) -> str:
    return f"{CONVERSATIONS_ROOT}/{actor}"


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
    query = urllib.parse.urlencode({"path": path, "limit": 200})
    result = _request(base_url, api_key, actor, "GET", f"/notes?{query}")
    for item in result.get("items", []):
        if item.get("title") == title:
            return item
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


def append_line(base_url: str, api_key: str, actor: str, title: str, path: str, line: str) -> None:
    note = find_note_by_title(base_url, api_key, actor, title, path)
    if note is None:
        create_note(base_url, api_key, actor, title, line, path)
        return
    for _ in range(MAX_RETRIES):
        current = _request(base_url, api_key, actor, "GET", f"/notes/{note['id']}")
        existing = current.get("content", "")
        content = f"{existing.rstrip(chr(10))}\n\n{line}" if existing else line
        try:
            update_note(base_url, api_key, actor, note["id"], current["version"], content)
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


def run(payload: Dict[str, Any]) -> None:
    base_url = os.environ.get("ROBOT_NOTES_BASE_URL", "").rstrip("/")
    api_key = os.environ.get("ROBOT_NOTES_API_KEY", "")
    actor = os.environ.get("ROBOT_NOTES_ACTOR", "claude-code")
    if not base_url or not api_key:
        return

    line = format_line(payload)
    if line is None:
        return

    session_id = payload.get("session_id") or "unknown-session"
    try:
        append_line(base_url, api_key, actor, session_id, conversations_path(actor), line)
    except Exception:
        pass  # best-effort logging only; never surface a failure here


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
