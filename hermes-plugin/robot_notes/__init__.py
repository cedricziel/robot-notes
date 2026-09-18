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
from .recall import RecallCache, RecallStatus, is_trivial_prompt
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
        self._recall_cache = RecallCache()
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

    @property
    def _prefetch_thread(self) -> Optional[threading.Thread]:
        """Exposed for tests: the background thread started by the most recent
        queue_prefetch(), if any. Cache bookkeeping itself lives in RecallCache."""
        return self._recall_cache.thread

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Queues the search off the caller's thread, keyed by (session_id, query) —
        this must return immediately so a per-turn call site never blocks on network
        latency; prefetch() picks up a matching result on the following turn. Skipped
        for trivial prompts ("ok", "thanks", ...), which carry no recall signal.

        The background work is spawned via ``spawn_context_thread`` (never a bare
        ``threading.Thread``): under the Hermes host, profile home and the per-turn
        secret scope live in contextvars, and only that helper carries them onto the
        background thread. It's passed into the cache rather than imported by
        ``recall.py`` so this module-level name stays the one thing to monkeypatch."""
        if is_trivial_prompt(query):
            return
        self._recall_cache.queue(session_id, query, self._search_and_format, spawn_thread=spawn_context_thread)

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if is_trivial_prompt(query):
            return self._recall_cache.note_result("", 0)
        cached = self._recall_cache.consume(session_id, query)
        formatted, count = cached if cached is not None else self._search_and_format(query)
        return self._recall_cache.note_result(formatted, count)

    def recall_status(self) -> Optional[RecallStatus]:
        return self._recall_cache.status("robot-notes")

    def _search_and_format(self, query: str) -> "tuple[str, int]":
        if not self._client or not query:
            return "", 0
        try:
            items = self._client.search(query, limit=5)
        except ClientError:
            return "", 0
        if not items:
            return "", 0
        items = items[:5]
        lines = [
            f"- {item['title']} (id: {item.get('id', '')}, {item.get('path', '')}): "
            f"{_MARK_RE.sub('', item.get('snippet', ''))}"
            for item in items
        ]
        return "Relevant notes from robot-notes:\n" + "\n".join(lines), len(items)

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
        Also bumps the recall cache's generation and drops every cached entry (for every
        session, not just this one) so a recall queued before the switch — for this
        session or another one sharing this provider instance — cannot land in the cache
        and be injected after it."""
        self._session_id = str(new_session_id or "").strip() or self._session_id
        self._recall_cache.clear()

    def _conversations_path(self) -> str:
        return f"{CONVERSATIONS_ROOT}/{_sanitize_actor(self._config.actor)}"

    def on_memory_write(
        self, action: str, target: str, content: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        """Mirror one built-in-memory write onto the matching note as an entry-level
        edit — never a blind overwrite of the whole note.

        Hermes' built-in memory tool (``tools/memory_tool.py``) identifies the entry a
        ``replace``/``remove`` targets by ``old_text``: "a short unique substring of
        the entry", not necessarily the whole line, and matched with plain substring
        containment (``tools/memory_tool_store.py::_find_unique_match``). The bridge
        (``MemoryManager.notify_memory_tool_write``) forwards that as
        ``metadata["old_text"]`` and puts the *new* text in ``content`` — so for
        ``remove``, ``content`` is normally empty and the entry to delete is named by
        ``metadata["old_text"]`` alone.
        """
        if not self._client or not self._can_write():
            return
        note = USER_NOTE if target == "user" else MEMORY_NOTE
        old_text = str((metadata or {}).get("old_text") or "").strip()
        try:
            if action == "add":
                self._append_note(title=note["title"], path=note["path"], addition=content)
            elif action == "remove":
                # Some callers (direct/legacy on_memory_write invocations with no
                # metadata) pass the entry to remove as `content` instead.
                self._remove_note_entry(title=note["title"], path=note["path"], identifier=old_text or content)
            else:  # replace
                self._replace_note_entry(
                    title=note["title"], path=note["path"], identifier=old_text, new_entry=content
                )
        except ClientError:
            logger.warning("robot_notes: failed to mirror memory write (target=%s action=%s)", target, action)

    def _overwrite_note(self, *, title: str, path: str, content: str, create_if_missing: bool = True) -> None:
        """Create-or-blind-overwrite a fixed note by title, swallowing failures with a
        logged warning — these are best-effort side writes, never allowed to raise out
        of a MemoryProvider hook and take the host session down with them. Used only
        for whole-note content (session summaries); memory-write mirroring never
        overwrites a whole note — see ``_read_edit_write``."""
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
        """Append ``addition`` as a new entry, skipping it if an identical entry
        (compared line-for-line after ``strip()``) is already present."""

        def edit(current: str) -> Optional[str]:
            entries = current.split("\n") if current else []
            if any(entry.strip() == addition.strip() for entry in entries):
                return None  # duplicate entry — nothing to add
            return f"{current.rstrip(chr(10))}\n{addition}" if current else addition

        self._read_edit_write(title=title, path=path, edit=edit, create_content_if_missing=addition)

    def _remove_note_entry(self, *, title: str, path: str, identifier: str) -> None:
        """Delete only the entry matching ``identifier`` (see ``_find_entry_index``).
        No match, an ambiguous match, or a missing note all leave the note exactly as
        it was — a single entry removal must never blank or rewrite the whole note."""

        def edit(current: str) -> Optional[str]:
            entries = current.split("\n") if current else []
            index = _find_entry_index(entries, identifier)
            if index is None:
                return None  # nothing safe to remove — leave the note untouched
            del entries[index]
            return "\n".join(entries)

        self._read_edit_write(title=title, path=path, edit=edit)

    def _replace_note_entry(self, *, title: str, path: str, identifier: str, new_entry: str) -> None:
        """Replace the entry matching ``identifier`` with ``new_entry`` in place. When
        the old entry can't be identified (no usable ``identifier``, no match, or an
        ambiguous match) this falls back to appending ``new_entry`` instead — the new
        fact is never dropped, and unrelated entries are never touched."""

        def edit(current: str) -> Optional[str]:
            entries = current.split("\n") if current else []
            index = _find_entry_index(entries, identifier) if identifier else None
            if index is None:
                if any(entry.strip() == new_entry.strip() for entry in entries):
                    return None  # already present verbatim
                return f"{current.rstrip(chr(10))}\n{new_entry}" if current else new_entry
            entries[index] = new_entry
            return "\n".join(entries)

        self._read_edit_write(title=title, path=path, edit=edit, create_content_if_missing=new_entry)

    def _read_edit_write(
        self,
        *,
        title: str,
        path: str,
        edit: Callable[[str], Optional[str]],
        create_content_if_missing: Optional[str] = None,
        max_attempts: int = 3,
    ) -> None:
        """Read-edit-write a note without ever blanking or overwriting the parts an
        edit doesn't touch: ``edit(current_content)`` returns the full new content, or
        ``None`` to make no change at all (in which case nothing is written — the
        note is left exactly as it was). Retries on a lost version race, mirroring
        ``RobotNotesClient.append_note_with_retry``'s read-modify-write-retry shape.
        When the note doesn't exist yet, ``create_content_if_missing`` (if given)
        creates it with that content instead of running ``edit``."""
        existing = self._client.find_note_by_title(title, path=path)
        if existing is None:
            if create_content_if_missing is not None:
                self._client.create_note(title=title, content=create_content_if_missing, path=path)
            return
        for attempt in range(max_attempts):
            note = self._client.get_note(existing["id"])
            current = note.get("content", "")
            new_content = edit(current)
            if new_content is None or new_content == current:
                return
            try:
                self._client.update_note(existing["id"], version=note["version"], content=new_content)
                return
            except ClientError as exc:
                if not exc.version_conflict or attempt == max_attempts - 1:
                    raise

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


def _find_entry_index(entries: List[str], identifier: str) -> Optional[int]:
    """Locate the entry ``identifier`` names, mirroring how Hermes' built-in memory
    tool matches ``old_text``: an exact match against the entry's stripped text
    first, else the unique entry containing ``identifier`` as a substring (``old_text``
    is documented as "a short unique substring of the entry", not always the whole
    line). Returns ``None`` when nothing matches, or when the substring appears in
    more than one *distinct* entry — an ambiguous identifier must never cause a
    guess at which entry to touch."""
    identifier = (identifier or "").strip()
    if not identifier:
        return None
    exact = [i for i, entry in enumerate(entries) if entry.strip() == identifier]
    if exact:
        return exact[0]
    contains = [i for i, entry in enumerate(entries) if identifier in entry]
    if not contains:
        return None
    if len({entries[i].strip() for i in contains}) > 1:
        return None
    return contains[0]
