"""Hermes Agent MemoryProvider plugin backed by a robot-notes workspace.

Talks to robot-notes' existing bearer-key REST API directly (no MCP client).
Writes are deliberately sparse: session-end summaries, explicit tool calls,
and mirrored built-in-memory writes only — never one write per turn.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from ._hermes_compat import MemoryProvider, spawn_context_thread, tool_error
from .client import ClientError, RobotNotesClient
from .config import DEFAULT_ACTOR, RobotNotesConfig
from .transcript import build_transcript

logger = logging.getLogger(__name__)

CONVERSATIONS_ROOT = "conversations"
MEMORY_NOTE = {"title": "Memory", "path": "Hermes"}
USER_NOTE = {"title": "User", "path": "Hermes"}

SKILLS_DIR = Path(__file__).parent / "skills"
SKILL_NAME = "robot-notes"
SKILL_PATH = SKILLS_DIR / SKILL_NAME / "SKILL.md"
SKILL_DESCRIPTION = (
    "Search-before-create and append-not-duplicate discipline for the "
    "robotnotes_* tools backing this shared notes workspace."
)

SYSTEM_PROMPT_BLOCK = (
    "A shared robot-notes workspace is connected as external memory. Call "
    "robotnotes_search before creating a new note, and robotnotes_remember "
    "to store a fact worth keeping across sessions. robotnotes_search is "
    "keyword search only — to browse or list every note in the workspace, "
    "use robotnotes_list instead."
)

_MARK_RE = re.compile(r"</?mark>")

# Tool calls that write to the workspace; gated on _write_enabled. robotnotes_search,
# robotnotes_list and robotnotes_note stay available in every agent context.
WRITE_TOOL_NAMES = frozenset({"robotnotes_remember", "robotnotes_forget"})


def _sanitize_actor(actor: str) -> str:
    """Collapses an actor value to exactly one safe path segment: flattens any
    '/' (so a misconfigured actor can't nest extra folders under
    conversations/) and falls back to DEFAULT_ACTOR for anything that would
    resolve to a no-op or traversal segment ("", ".", "..")."""
    cleaned = actor.replace("/", "_").strip()
    return cleaned if cleaned and cleaned not in (".", "..") else DEFAULT_ACTOR


def _write_disabled_error() -> str:
    return tool_error(
        "This agent context is read-only; writes are limited to the "
        "primary agent context (this session is a subagent, cron, or flush "
        "context).",
        code="read_only",
    )


def register(ctx) -> None:
    ctx.register_memory_provider(RobotNotesProvider())
    if hasattr(ctx, "register_skill"):
        ctx.register_skill(SKILL_NAME, SKILL_PATH, SKILL_DESCRIPTION)


class RobotNotesProvider(MemoryProvider):
    def __init__(self) -> None:
        self._config: Optional[RobotNotesConfig] = None
        self._client: Optional[RobotNotesClient] = None
        self._session_id: str = ""
        # Backwards-compatible default: a host that never passes agent_context (or an
        # older Hermes build) must keep writing, so only an explicit non-primary
        # value in initialize() below turns this off.
        self._write_enabled: bool = True
        self._hermes_home: str = ""
        self._platform: str = ""
        self._agent_identity: str = ""
        self._prefetch_cache: str = ""
        self._prefetch_lock = threading.Lock()
        self._prefetch_thread: Optional[threading.Thread] = None
        self._prefetch_generation = 0
        self._tools = [
            {
                "name": "robotnotes_search",
                "description": "Search the shared robot-notes workspace. This is keyword "
                "full-text search, not a wildcard — there is no query that means "
                "\"every note\" (a query like '*' is rejected, and a generic term "
                "like 'notes' only matches notes that literally contain that word). "
                "To enumerate everything in the workspace, use robotnotes_list "
                "instead.",
                "parameters": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"],
                },
                "handler": self._tool_search,
            },
            {
                "name": "robotnotes_list",
                "description": "List every note's metadata (id, title, path, version, "
                "timestamps — no content) from the shared robot-notes workspace, "
                "optionally narrowed to a folder with 'path'. Paginated: call again "
                "with 'after' set to the previous response's next_cursor until it "
                "comes back null to see the whole workspace. Use this instead of "
                "robotnotes_search to browse or enumerate everything.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "after": {"type": "string"},
                        "limit": {"type": "integer"},
                    },
                    "required": [],
                },
                "handler": self._tool_list,
            },
            {
                "name": "robotnotes_note",
                "description": "Fetch a note from the shared robot-notes workspace by id.",
                "parameters": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
                "handler": self._tool_note,
            },
            {
                "name": "robotnotes_remember",
                "description": "Store a durable fact as a new note in the shared robot-notes workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {"title": {"type": "string"}, "content": {"type": "string"}},
                    "required": ["title", "content"],
                },
                "handler": self._tool_remember,
            },
            {
                "name": "robotnotes_forget",
                "description": "Delete a note this agent created from the shared robot-notes workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
                "handler": self._tool_forget,
            },
        ]

    @property
    def name(self) -> str:
        return "robot_notes"

    def is_available(self) -> bool:
        return self._load_config().is_complete

    def unavailable_reason(self) -> str:
        return self._load_config().missing_reason or ""

    def _load_config(self) -> RobotNotesConfig:
        if self._config is None:
            self._config = RobotNotesConfig.load()
        return self._config

    def initialize(self, session_id: str, **kwargs) -> None:
        self._config = RobotNotesConfig.load(kwargs.get("hermes_home"))
        self._session_id = session_id
        self._write_enabled = kwargs.get("agent_context", "") not in {"cron", "flush", "subagent"}
        self._hermes_home = kwargs.get("hermes_home") or ""
        self._platform = kwargs.get("platform") or ""
        self._agent_identity = kwargs.get("agent_identity") or ""
        self._client = RobotNotesClient(
            base_url=self._config.base_url, api_key=self._config.api_key, actor=self._config.actor
        )

    def shutdown(self) -> None:
        if self._client:
            self._client.close()

    def system_prompt_block(self) -> str:
        return SYSTEM_PROMPT_BLOCK

    def backup_paths(self) -> List[str]:
        return []

    def _can_write(self) -> bool:
        return self._write_enabled

    # -- Recall ---------------------------------------------------------

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Runs the search off the caller's thread — this must return immediately so a
        per-turn call site never blocks on network latency; prefetch() picks up the
        result (if ready by then) on the following turn. A generation counter stops a
        slow, superseded search from clobbering a faster, more recent one.

        Spawned via ``spawn_context_thread`` (never a bare ``threading.Thread``): under the
        Hermes host, profile home and the per-turn secret scope live in contextvars, and only
        that helper carries them onto the background thread."""
        self._prefetch_generation += 1
        generation = self._prefetch_generation

        def _run() -> None:
            result = self._search_and_format(query)
            with self._prefetch_lock:
                if generation == self._prefetch_generation:
                    self._prefetch_cache = result

        thread = spawn_context_thread(_run, name="robot-notes-prefetch")
        self._prefetch_thread = thread
        thread.start()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._prefetch_lock:
            cached, self._prefetch_cache = self._prefetch_cache, ""
        if cached:
            return cached
        return self._search_and_format(query)

    def _search_and_format(self, query: str) -> str:
        if not self._client or not query:
            return ""
        try:
            items = self._client.search(query)
        except ClientError:
            return ""
        if not items:
            return ""
        lines = [f"- {item['title']}: {_MARK_RE.sub('', item.get('snippet', ''))}" for item in items[:5]]
        return "Relevant notes from robot-notes:\n" + "\n".join(lines)

    # -- Explicit tools ---------------------------------------------------

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [{"name": t["name"], "description": t["description"], "parameters": t["parameters"]} for t in self._tools]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        if not self._client:
            return tool_error("robot_notes provider is unavailable", code="unavailable")
        if tool_name in WRITE_TOOL_NAMES and not self._can_write():
            return _write_disabled_error()
        tool = next((t for t in self._tools if t["name"] == tool_name), None)
        if tool is None:
            return tool_error(f"robot_notes does not handle tool {tool_name}", code="unknown_tool")
        try:
            return tool["handler"](args)
        except ClientError as exc:
            code = (
                "not_found"
                if exc.not_found
                else "version_conflict"
                if exc.version_conflict
                else "network_error"
                if exc.network_error
                else "error"
            )
            return tool_error(str(exc), code=code)

    def _tool_search(self, args: Dict[str, Any]) -> str:
        return json.dumps({"items": self._client.search(args["query"])})

    def _tool_list(self, args: Dict[str, Any]) -> str:
        return json.dumps(
            self._client.list_notes(
                path=args.get("path"), after=args.get("after"), limit=args.get("limit", 50)
            )
        )

    def _tool_note(self, args: Dict[str, Any]) -> str:
        return json.dumps(self._client.get_note(args["id"]))

    def _tool_remember(self, args: Dict[str, Any]) -> str:
        return json.dumps(self._client.create_note(title=args["title"], content=args.get("content", "")))

    def _tool_forget(self, args: Dict[str, Any]) -> str:
        return json.dumps(self._client.delete_note(args["id"]))

    # -- Sparse writes: session summary + built-in memory mirror ----------

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        if not self._client or not self._can_write():
            return
        title = self._session_id or "unknown-session"
        content = build_transcript(messages, session_id=title, actor=self._config.actor)
        self._overwrite_note(title=title, path=self._conversations_path(), content=content)

    def on_session_switch(
        self,
        new_session_id: str,
        *,
        parent_session_id: str = "",
        reset: bool = False,
        rewound: bool = False,
        **kwargs,
    ) -> None:
        """session_id reassigned mid-process (/new, /resume, /branch, /reset, compression)
        without a matching initialize(): rebind so the *next* on_session_end writes to a
        note named after the new session instead of overwriting the previous session's note
        under it. A blank new_session_id is ignored (some callers reassign a rewind in place).
        Also bumps the prefetch generation and drops any cached prefetch so a recall queued
        for the old session cannot be injected into the new one."""
        self._session_id = str(new_session_id or "").strip() or self._session_id
        self._prefetch_generation += 1
        with self._prefetch_lock:
            self._prefetch_cache = ""

    def _conversations_path(self) -> str:
        return f"{CONVERSATIONS_ROOT}/{_sanitize_actor(self._config.actor)}"

    def on_memory_write(
        self, action: str, target: str, content: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        if not self._client or not self._can_write():
            return
        note = USER_NOTE if target == "user" else MEMORY_NOTE
        try:
            if action == "add":
                self._append_note(title=note["title"], path=note["path"], addition=content)
            elif action == "remove":
                self._overwrite_note(title=note["title"], path=note["path"], content="", create_if_missing=False)
            else:  # replace
                self._overwrite_note(title=note["title"], path=note["path"], content=content)
        except ClientError:
            logger.warning("robot_notes: failed to mirror memory write (target=%s action=%s)", target, action)

    def _overwrite_note(self, *, title: str, path: str, content: str, create_if_missing: bool = True) -> None:
        """Create-or-blind-overwrite a fixed note by title, swallowing failures with a
        logged warning — these are best-effort side writes, never allowed to raise out
        of a MemoryProvider hook and take the host session down with them."""
        try:
            existing = self._client.find_note_by_title(title, path=path)
            if existing is None:
                if create_if_missing:
                    self._client.create_note(title=title, content=content, path=path)
                return
            self._client.write_note_with_retry(existing["id"], version=existing["version"], content=content)
        except ClientError:
            logger.warning("robot_notes: failed to write note %r under %r", title, path)

    def _append_note(self, *, title: str, path: str, addition: str) -> None:
        build_content: Callable[[str], str] = lambda current: f"{current.rstrip(chr(10))}\n{addition}" if current else addition
        existing = self._client.find_note_by_title(title, path=path)
        if existing is None:
            self._client.create_note(title=title, content=addition, path=path)
            return
        self._client.append_note_with_retry(existing["id"], build_content=build_content)

    # -- Setup wizard -------------------------------------------------------

    def get_config_schema(self) -> List[Dict[str, Any]]:
        """Kept minimal per the memory-provider-plugin guide: every field here is
        prompted during `hermes memory setup`. `actor` is optional (defaults to
        "hermes") and rarely needs changing, so it is documented in
        robot_notes.json's reference table in the README instead of prompted for
        here; set it by hand in robot_notes.json when the default is not right."""
        return [
            {"key": "base_url", "description": "robot-notes server base URL", "required": True, "type": "text"},
            {
                "key": "api_key",
                "description": "robot-notes API key",
                "required": True,
                "secret": True,
                "env_var": "ROBOT_NOTES_API_KEY",
            },
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        RobotNotesConfig.create(base_url=str(values.get("base_url", "")), actor=str(values.get("actor") or "")).save(
            hermes_home
        )
