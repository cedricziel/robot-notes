"""Hermes Agent MemoryProvider plugin backed by a robot-notes workspace.

Talks to robot-notes' existing bearer-key REST API directly (no MCP client).
Writes are deliberately sparse: session-end summaries, explicit tool calls,
and mirrored built-in-memory writes. Optional evidence capture queues supplied
completed-turn JSON separately from readable notes.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import sqlite3
import threading
from itertools import zip_longest
from pathlib import Path
from typing import Any, Dict, List, Optional

from ._hermes_compat import MemoryProvider, spawn_context_thread, tool_error
from .client import ClientError, ErrorKind, RobotNotesClient
from .correction_proposals import source_references
from .curated_writes import deliver_write, ordinary_outcome, permissions_for_target, prepare_write, read_note_for_write
from .memory_corrections import plan_memory_edit
from .config import DEFAULT_ACTOR, RobotNotesConfig, _default_hermes_home
from .evidence import EvidenceArchive
from .health import MemoryHealth
from .outbox import Outbox, QueueFull
from .recall import RecallCache, RecallStatus, is_trivial_prompt
from .recall_evidence import evidence_context, narrow_paths
from .tools import TOOL_HANDLERS, TOOL_SCHEMAS
from .transcript import build_transcript

logger = logging.getLogger(__name__)


class _DeliveryCancelled(Exception):
    pass


CONVERSATIONS_ROOT = "conversations"

SKILLS_DIR = Path(__file__).parent / "skills"
SKILL_NAME = "robot-notes"
SKILL_PATH = SKILLS_DIR / SKILL_NAME / "SKILL.md"
SKILL_DESCRIPTION = (
    "Search-before-create and append-not-duplicate discipline for the "
    "robotnotes_* tools backing this shared notes workspace."
)

_MARK_RE = re.compile(r"</?mark>")

# Tool calls that write to the workspace; gated on _write_enabled. robotnotes_search,
# robotnotes_list and robotnotes_note stay available in every agent context.
WRITE_TOOL_NAMES = frozenset({"robotnotes_remember", "robotnotes_append", "robotnotes_forget"})


def _append_line(current: str, addition: str) -> str:
    """Appends ``addition`` to ``current`` the same way the server's
    ``POST /notes/{id}/append`` does (``NoteWriteService.append``): ``current``
    empty means the addition becomes the whole content; otherwise a single
    ``\\n`` separator is inserted only when ``current`` doesn't already end
    with one (so a note that already ends on a blank line doesn't grow an
    extra one). Used only by ``_tool_append``'s fallback path
    (``append_note_with_retry``, for a server predating the append endpoint);
    Memory mirrors use the exact-entry correction planner for duplicate detection."""
    if not current:
        return addition
    return current + ("" if current.endswith("\n") else "\n") + addition

# Fallback error codes for ``handle_tool_call``, used only when the server's
# response didn't carry an explicit ``code`` of its own (e.g. a network
# failure never reaches the server at all).
_FALLBACK_ERROR_CODES: Dict[ErrorKind, str] = {
    ErrorKind.NOT_FOUND: "not_found",
    ErrorKind.VERSION_CONFLICT: "version_conflict",
    ErrorKind.PATH_CONFLICT: "path_conflict",
    ErrorKind.LOCKED: "locked",
    ErrorKind.AUTH: "unauthorized",
    ErrorKind.NETWORK_ERROR: "network_error",
    ErrorKind.CIRCUIT_OPEN: "circuit_open",
    ErrorKind.OTHER: "error",
}

_PATH_CONFLICT_REMEMBER_MESSAGE = (
    "A note with this title already exists at this path. Use robotnotes_search "
    "or robotnotes_list to find it, then append to or update that note instead "
    "of creating a duplicate."
)


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
        self._evidence_archive: Optional[EvidenceArchive] = None
        self._evidence_outbox = None
        self._evidence_thread: Optional[threading.Thread] = None
        self._evidence_lineage: dict = {}
        self._evidence_session_lineage: dict = {}
        self._evidence_capture_error = False
        self._health = MemoryHealth()
        self._outbox: Optional[Outbox] = None
        self._delivery_thread: Optional[threading.Thread] = None
        self._delivery_lock = threading.Lock()
        self._delivery_epoch = 0
        self._delivery_enabled = False

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

    @property
    def pre_compress_checkpoint_api_version(self) -> int:
        return 2 if self._evidence_archive and self._client and self._config.is_complete and self._can_write() else 1

    def initialize(self, session_id: str, **kwargs) -> None:
        if self._evidence_archive:
            self._evidence_archive.stop()
        if self._evidence_thread:
            self._evidence_thread.join(timeout=10)
        self._evidence_thread = None
        self._evidence_archive = None
        self._evidence_outbox = None
        self._evidence_lineage = {}
        self._evidence_session_lineage = {}
        self._evidence_capture_error = False
        # Invalidate cached and in-flight recall before rebinding the server/vault.
        self._delivery_epoch += 1
        self._delivery_enabled = False
        old_client = self._client
        self._client = None
        self._recall_cache.clear()
        self._health = MemoryHealth()
        if old_client:
            old_client.close()
        self._outbox = None
        self._config = RobotNotesConfig.load(kwargs.get("hermes_home"))
        self._session_id = session_id
        self._write_enabled = kwargs.get("agent_context", "") not in {"cron", "flush", "subagent"}
        self._hermes_home = kwargs.get("hermes_home") or ""
        self._platform = kwargs.get("platform") or ""
        self._agent_identity = kwargs.get("agent_identity") or ""
        self._client = RobotNotesClient(
            base_url=self._config.base_url,
            api_key=self._config.api_key,
            actor=self._config.actor,
            vault_id=self._config.vault_id,
        )
        if self._config.durable_writes and self._can_write():
            identity = {key: getattr(self._config, key) for key in ("base_url", "vault_id", "actor", "api_key")}
            identity.update(memory_scope=None, user_id=None, agent_id=None)
            if self._config.memory_scope == "identity":
                identity.update(memory_scope="identity", user_id=self._config.user_id, agent_id=self._config.agent_id)
            destination = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
            home = Path(self._hermes_home or _default_hermes_home())
            self._outbox = Outbox(home / "robot_notes_outbox" / destination / "queue.sqlite")
            self._delivery_enabled = True
            self._start_delivery()

        if self._config.evidence_archive and self._config.is_complete and self._can_write():
            home = Path(self._hermes_home or _default_hermes_home())
            self._evidence_archive = EvidenceArchive(self._config, home)
            self._evidence_outbox = self._evidence_archive.outbox

    def shutdown(self) -> None:
        if self._evidence_archive:
            self._evidence_archive.stop()
        if self._evidence_thread:
            self._evidence_thread.join(timeout=10)
        self._evidence_thread = None
        self._evidence_archive = None
        self._evidence_outbox = None
        self._delivery_enabled = False
        self._delivery_epoch += 1
        if self._client:
            self._client.close()
            self._client = None

    def system_prompt_block(self) -> str:
        convo_path = self._conversations_path() if self._config else f"{CONVERSATIONS_ROOT}/<actor>"
        config = self._load_config()
        memory_note, user_note = config.memory_note, config.user_note
        scope_hint = f"Memory organization mode: {config.memory_scope}. Folder scope does not grant server access. "
        if not self._load_config().native_tools:
            return (
                "A shared robot-notes workspace is connected for automatic memory recall. "
                f"Selected vault: {self._config.vault_id}. Automatic memory hooks use this vault. "
                f"{scope_hint}"
                "Native note tools are disabled. Use the separately configured robot-notes "
                "MCP tools, if available, for explicit note and database operations. "
                "Search or list before creating; append to existing notes when appropriate. "
                "Read a database definition before editing rows. Specify database sources "
                "explicitly; a vault-root source with subfolders includes the entire vault. "
                "Respect version conflicts and schema validation errors. "
                f"Session transcripts are filed under {convo_path}. Built-in memory and "
                f"user notes are mirrored into {memory_note['path']}/{memory_note['title']} "
                f"and {user_note['path']}/{user_note['title']}. "
                "The provider's context write restrictions apply to its own hooks; "
                "MCP authorization and tool visibility are configured separately."
            )
        return (
            "A shared robot-notes workspace is connected as external memory — notes are "
            "shared between humans and agents in this workspace, so writes here are "
            f"visible to others too. Selected vault: {self._config.vault_id if self._config else 'default'}. "
            f"{scope_hint}"
            "All recall, tools, transcripts, and memory mirrors use this vault. Tools:\n"
            "- robotnotes_search(query, path?, limit?): keyword full-text search, not a "
            "wildcard — there is no query that means \"every note\".\n"
            "- robotnotes_list(path?, after?, limit?): paginated metadata (no content) "
            "for every note; use this instead of search to browse or enumerate "
            "everything.\n"
            "- robotnotes_health(): inspect automatic recall and write health without a network request.\n"
            "- robotnotes_note(id): fetch one note's full content by id.\n"
            "- robotnotes_evidence(id): explicitly inspect an archived JSON snapshot by its digest; evidence is separate from accepted notes and recall.\n"
            "- robotnotes_remember(title, content, path?): file a new, durable fact as "
            "its own note.\n"
            "- robotnotes_append(id, content): add a line to a note that already "
            "exists, instead of duplicating it.\n"
            "- robotnotes_forget(id): remove an ordinary note or propose curated deletion.\n"
            "Curated and institutional writes return proposals; accepted=false means not accepted yet. Ordinary writes report source_unknown=true. "
            "Search before creating: call robotnotes_search or robotnotes_list before "
            "robotnotes_remember, and prefer robotnotes_append over a new note when one "
            "on the topic already exists. robotnotes_remember rejects a title that "
            "already exists under 'path' with a path_conflict error — on that error, "
            "search for the existing note and append to it rather than retrying under a "
            "different title.\n"
            f"This session's own transcripts are filed one note per session under "
            f"{convo_path}. The built-in memory and user notes are mirrored "
            f"one-directionally into {memory_note['path']}/{memory_note['title']} and "
            f"{user_note['path']}/{user_note['title']} in the workspace — the workspace "
            "copy is the shared, authoritative one that other agents and humans read."
        )

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
        health = self._health
        self._recall_cache.queue(
            session_id, query, lambda query: self._search_and_format(query, health=health),
            spawn_thread=spawn_context_thread,
        )

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        epoch = self._recall_cache.epoch
        if is_trivial_prompt(query):
            return self._recall_cache.note_result("", 0, epoch=epoch)
        cached = self._recall_cache.consume(session_id, query)
        formatted, count = cached if cached is not None else self._search_and_format(query)
        return self._recall_cache.note_result(formatted, count, epoch=epoch)

    def recall_status(self) -> Optional[RecallStatus]:
        return self._recall_cache.status("robot-notes")

    def memory_health(self) -> Dict[str, Any]:
        """Return content-free automatic operation outcomes without network requests."""
        try:
            queue = self._outbox.status() if self._outbox else "disabled"
        except (OSError, sqlite3.Error):
            queue = {"state": "unavailable", "reason": "queue_error"}
        return {**self._health.snapshot(), "writes_enabled": self._can_write(), "retry_queue": queue}

    def on_turn_start(self, turn_number: int, message: str, **kwargs) -> None:
        self._start_delivery()
        self._start_evidence_delivery()

    def flush_memory_writes(self, timeout: float = 2.0, *, retry_blocked: bool = False) -> None:
        """Request delivery and wait briefly; permanent failures retry only when explicit."""
        if retry_blocked and self._outbox:
            self._outbox.retry_blocked()
        self._start_delivery()
        thread = self._delivery_thread
        if thread:
            thread.join(timeout)

    def _enqueue_automatic(self, operation: Dict[str, Any]) -> None:
        try:
            self._outbox.enqueue(operation)
        except (QueueFull, OSError, sqlite3.Error) as exc:
            operation_name = "mirror" if operation["kind"] == "mirror" else "transcript"
            generation = self._health.begin(operation_name)
            self._health.finish(operation_name, generation, "failed", "queue_full" if isinstance(exc, QueueFull) else "queue_error")
            return
        self._start_delivery()

    def _start_delivery(self) -> None:
        outbox, config, health, epoch = self._outbox, self._config, self._health, self._delivery_epoch
        if not self._delivery_enabled or not outbox or not self._can_write() or not self._delivery_lock.acquire(blocking=False):
            return

        def classify(exc):
            if isinstance(exc, _DeliveryCancelled):
                return "cancelled", True
            if isinstance(exc, ClientError):
                retryable = exc.kind in {ErrorKind.NETWORK_ERROR, ErrorKind.CIRCUIT_OPEN} or (exc.status or 0) >= 500
                return exc.kind.name.lower(), retryable
            return "delivery_error", False

        def run():
            sender = RobotNotesProvider()
            sender._config = config
            sender._client = RobotNotesClient(base_url=config.base_url, api_key=config.api_key, actor=config.actor, vault_id=config.vault_id)
            try:
                def deliver(operation):
                    if not self._delivery_enabled or self._delivery_epoch != epoch:
                        raise _DeliveryCancelled()
                    name = "mirror" if operation["kind"] == "mirror" else "transcript"
                    generation = health.begin(name)
                    try:
                        result = sender._deliver_automatic(operation)
                    except Exception as exc:
                        health.finish(name, generation, "failed", classify(exc)[0])
                        raise
                    health.finish(name, generation, sender._write_outcome(result), source_unknown=result.get("source_unknown"))

                for _ in range(20):
                    if not self._delivery_enabled or self._delivery_epoch != epoch:
                        break
                    if not outbox.deliver_one(deliver, classify, sender._prepare_automatic, sender._upgrade_automatic):
                        break
            finally:
                sender._client.close()
                self._delivery_lock.release()
                if self._delivery_epoch != epoch and self._delivery_enabled:
                    self._start_delivery()

        try:
            thread = spawn_context_thread(run, name="robot-notes-delivery")
            thread.daemon = True
            self._delivery_thread = thread
            thread.start()
        except Exception:
            self._delivery_lock.release()
            raise

    def _prepare_automatic(self, operation: Dict[str, Any]) -> Dict[str, Any]:
        note = operation.get("note") or operation
        existing = self._client.find_note_by_title(note["title"], path=note["path"])
        current = read_note_for_write(self._client, existing["id"]) if existing else None
        if current and (current["title"] != note["title"] or current["path"] != note["path"]):
            raise ClientError("Prepared destination moved", kind=ErrorKind.PATH_CONFLICT)
        desired = operation["content"]
        if operation["kind"] == "mirror":
            plan = plan_memory_edit(current.get("content", "") if current else "", operation["action"],
                                    desired, operation.get("metadata"))
            if plan.state == "unchanged":
                return {**operation, "prepared": {"schema": 2, "noop": True}}
            if plan.state != "changed":
                raise ClientError("Memory correction requires review", code="correction_requires_review",
                                  details={"reason": plan.reason})
            desired = plan.content
        try:
            refs = source_references(operation.get("metadata"))
        except ValueError as exc:
            raise ClientError("Invalid source references", code="invalid_evidence_refs") from exc
        prepared = prepare_write(self._client, current=current, title=note["title"], path=note["path"],
                                 desired=desired, refs=refs)
        return {**operation, "prepared": prepared}

    def _deliver_automatic(self, operation: Dict[str, Any]) -> Dict[str, Any]:
        prepared = operation["prepared"]
        if prepared.get("noop"):
            return {"accepted": False, "state": "unchanged", "source_unknown": True}
        if prepared.get("schema") == 2:
            return deliver_write(self._client, prepared)
        return self._deliver_automatic(self._upgrade_automatic(operation))

    def _upgrade_automatic(self, operation):
        prepared = operation["prepared"]
        if prepared.get("schema") == 2:
            return operation
        if prepared.get("noop"):
            return {**operation, "prepared": {"schema": 2, "noop": True}}
        if "id" in prepared:
            current = read_note_for_write(self._client, prepared["id"])
            if current.get("content", "") == prepared["content"]:
                return {**operation, "prepared": {"schema": 2, "noop": True}}
            if current["version"] != prepared["version"]:
                raise ClientError("Prepared note changed", kind=ErrorKind.VERSION_CONFLICT, status=409)
        else:
            existing = self._client.find_note_by_title(prepared["title"], path=prepared["path"])
            current = read_note_for_write(self._client, existing["id"]) if existing else None
            if current:
                if current.get("content", "") == prepared["content"]:
                    return {**operation, "prepared": {"schema": 2, "noop": True}}
                raise ClientError("Prepared destination changed", kind=ErrorKind.PATH_CONFLICT)
        if operation["kind"] == "mirror":
            plan = plan_memory_edit(current.get("content", "") if current else "", operation["action"],
                                    operation["content"], operation.get("metadata"))
            if plan.state != "changed" or plan.content != prepared["content"]:
                raise ClientError("Legacy prepared correction requires review", code="correction_requires_review")
        upgraded = prepare_write(self._client, current=current, title=prepared["title"], path=prepared["path"],
                                 desired=prepared["content"], refs=source_references(operation.get("metadata")))
        if upgraded["route"] in {"proposal", "proposal_create"}:
            raise ClientError("Legacy accepted effect now requires curated review", code="correction_requires_review")
        return {**operation, "prepared": upgraded}

    @staticmethod
    def _write_outcome(result):
        if not result or result.get("accepted") is not False:
            return "succeeded"
        state = result.get("state")
        if state == "denied":
            return "denied"
        if state in {"changes_requested", "needs_re_review", "conflicted"}:
            return "needs_review"
        return "succeeded" if state == "unchanged" else "pending_review"

    def _tool_health(self, args: Dict[str, Any]) -> str:
        return json.dumps(self.memory_health())

    def _search_and_format(self, query: str, *, health: Optional[MemoryHealth] = None) -> "tuple[str, int]":
        client = self._client
        if not client or not query:
            return "", 0
        health = health or self._health
        generation = health.begin("recall")
        try:
            items = self._recall_items(client, query)
            config = self._load_config()
            if config.recall_max_bytes:
                formatted, count = evidence_context(items[:5], max_bytes=config.recall_max_bytes,
                                                     expand_chars=config.recall_expand_chars,
                                                     recall_paths=narrow_paths(config.recall_paths, config.recall_path),
                                                     load_note=lambda note_id: client.get_note(note_id, recall=True))
                health.finish("recall", generation, "matched" if count else "empty")
                return formatted, count
        except ClientError as exc:
            if exc.kind is ErrorKind.CIRCUIT_OPEN:
                logger.debug("robot_notes: search unavailable (circuit_open)")
            health.finish("recall", generation, "failed", exc.kind.name.lower())
            return "", 0
        health.finish("recall", generation, "matched" if items else "empty")
        if not items:
            return "", 0
        items = items[:5]
        lines = [
            f"- {item['title']} (id: {item.get('id', '')}, {item.get('path', '')}): "
            f"{_MARK_RE.sub('', item.get('snippet', ''))}"
            for item in items
        ]
        return "Relevant notes from robot-notes:\n" + "\n".join(lines), len(items)

    def _recall_items(self, client: RobotNotesClient, query: str) -> List[Dict[str, Any]]:
        config = self._load_config()
        paths = narrow_paths(config.recall_paths, config.recall_path)
        if paths == (None,):
            return client.search(query, limit=5)
        results, errors = [None] * len(paths), [None] * len(paths)

        def search(index, path):
            try:
                results[index] = client.search(query, path=path, limit=5)
            except Exception as exc:
                errors[index] = exc

        threads = [spawn_context_thread(lambda index=index, path=path: search(index, path), name="robot-notes-scope") for index, path in enumerate(paths)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        for error in errors:
            if error is not None:
                raise error
        if not all(isinstance(result, list) for result in results):
            raise ClientError("Malformed search response", kind=ErrorKind.OTHER, code="invalid_response")
        for result in results:
            for item in result:
                if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                        or not item["id"] or not isinstance(item.get("title"), str)
                        or not isinstance(item.get("snippet", ""), str)):
                    raise ClientError("Malformed search result", kind=ErrorKind.OTHER, code="invalid_response")
        selected, seen = [], set()
        exhausted = object()
        for group in zip_longest(*results, fillvalue=exhausted):
            for item in group:
                if item is exhausted:
                    continue
                note_id = item["id"]
                if note_id not in seen:
                    selected.append(item)
                    seen.add(note_id)
                    if len(selected) == 5:
                        return selected
        return selected

    # -- Explicit tools ---------------------------------------------------

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        if not self._load_config().native_tools:
            return []
        return [dict(schema) for schema in TOOL_SCHEMAS]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        if not self._load_config().native_tools:
            return tool_error("Native robot-notes tools are disabled; use configured MCP tools.", code="tools_disabled")
        if not self._client:
            return tool_error("robot_notes provider is unavailable", code="unavailable")
        if tool_name in WRITE_TOOL_NAMES and not self._can_write():
            return _write_disabled_error()
        handler_name = TOOL_HANDLERS.get(tool_name)
        if handler_name is None:
            return tool_error(f"robot_notes does not handle tool {tool_name}", code="unknown_tool")
        try:
            args = dict(args)
            args["_source_metadata"] = {key: kwargs[key] for key in ("session_id", "turn_id", "tool_call_id", "task_id") if key in kwargs}
            return getattr(self, handler_name)(args)
        except ClientError as exc:
            payload = _tool_error_payload(exc, tool_name)
            return tool_error(payload["message"], code=payload["error"], details=payload["details"])

    def _tool_search(self, args: Dict[str, Any]) -> str:
        items = self._client.search(args["query"], path=args.get("path"), limit=args.get("limit", 20))
        return json.dumps({"items": items})

    def _tool_list(self, args: Dict[str, Any]) -> str:
        return json.dumps(
            self._client.list_notes(
                path=args.get("path"), after=args.get("after"), limit=args.get("limit", 50)
            )
        )

    def _tool_evidence(self, args: Dict[str, Any]) -> str:
        return json.dumps(self._client.get_evidence(args["id"]))

    def _tool_note(self, args: Dict[str, Any]) -> str:
        return json.dumps(self._client.get_note(args["id"]))

    def _native_curated(self, args, note_id=None):
        intent = args.get("curated_intent", False)
        if type(intent) is not bool:
            raise ClientError("curated_intent must be a boolean", code="invalid_arguments")
        target = {"id": note_id} if note_id else None
        policy = permissions_for_target(self._client, target, args.get("path", ""), args.get("title", ""), intent)
        return intent or (policy is not None and policy["curated"])

    def _native_refs(self, args):
        try:
            return source_references({**args.get("_source_metadata", {}), "evidence_refs": args.get("evidence_refs", [])})
        except ValueError as exc:
            raise ClientError("Invalid source references", code="invalid_evidence_refs") from exc

    def _tool_remember(self, args: Dict[str, Any]) -> str:
        if self._native_curated(args):
            prepared = prepare_write(self._client, current=None, title=args["title"], path=args.get("path", ""),
                desired=args.get("content", ""), refs=self._native_refs(args), curated_intent=True)
            return json.dumps(deliver_write(self._client, prepared))
        return json.dumps(ordinary_outcome(self._client.create_note(title=args["title"], content=args.get("content", ""), path=args.get("path", ""))))

    def _tool_append(self, args: Dict[str, Any]) -> str:
        note_id, addition = args["id"], args["content"]
        if self._native_curated(args, note_id):
            note = read_note_for_write(self._client, note_id)
            prepared = prepare_write(self._client, current=note, title=note["title"], path=note["path"],
                desired=_append_line(note["content"], addition), refs=self._native_refs(args), curated_intent=True)
            return json.dumps(deliver_write(self._client, prepared))
        try:
            note = self._client.append_note(note_id, addition)
        except ClientError as exc:
            if exc.status not in (404, 405):
                raise
            note = self._client.append_note_with_retry(note_id, build_content=lambda current: _append_line(current, addition))
        return json.dumps(ordinary_outcome(note))

    def _tool_forget(self, args: Dict[str, Any]) -> str:
        if self._native_curated(args, args["id"]):
            note = read_note_for_write(self._client, args["id"])
            prepared = prepare_write(self._client, current=note, title=note["title"], path=note["path"],
                desired="", refs=self._native_refs(args), curated_intent=True, delete_note=True)
            return json.dumps(deliver_write(self._client, prepared))
        return json.dumps(ordinary_outcome(self._client.delete_note(args["id"])))

    # -- Sparse writes: session summary + built-in memory mirror ----------

    def _start_evidence_delivery(self) -> None:
        archive = self._evidence_archive
        if not archive or (self._evidence_thread and self._evidence_thread.is_alive()):
            return
        thread = spawn_context_thread(archive.flush_best_effort, name="robot-notes-evidence")
        thread.daemon = True
        self._evidence_thread = thread
        thread.start()

    def sync_turn(
        self, user_content: str, assistant_content: str, *, session_id: str = "",
        messages: Optional[List[Dict[str, Any]]] = None,
        turn_author: Optional[Dict[str, Any]] = None,
    ) -> None:
        if not self._evidence_archive or not self._can_write():
            return
        capture = "raw_messages" if messages is not None else "text_fallback"
        supplied = messages if messages is not None else [
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
        capture_session = session_id or self._session_id
        lineage = self._evidence_session_lineage.get(capture_session, {})
        try:
            self._evidence_archive.enqueue(capture_session, "turn", supplied, capture, lineage)
        except Exception as exc:
            self._evidence_capture_error = True
            logger.warning("Conversation evidence capture failed (%s)", EvidenceArchive.failure_category(exc))
            return
        self._start_evidence_delivery()

    def flush_evidence(self, *, retry_blocked: bool = False) -> None:
        """Require acknowledgement of pending snapshots; explicitly retry permanent errors."""
        if self._evidence_archive and self._can_write():
            if retry_blocked:
                self._evidence_outbox.retry_blocked()
            self._evidence_archive.flush()

    def on_pre_compress(self, messages: List[Dict[str, Any]], *, require_checkpoint: bool = False) -> str:
        if not self._evidence_archive or not self._client or not self._can_write():
            if require_checkpoint:
                raise RuntimeError("Conversation evidence archive is disabled")
            return ""
        if self._evidence_capture_error:
            raise RuntimeError("Conversation evidence capture failed")
        self._evidence_archive.flush()
        digest = self._evidence_archive.enqueue(self._session_id, "checkpoint", messages,
                                       "host_normalized", self._evidence_lineage)
        self._evidence_archive.flush()
        if self._evidence_capture_error:
            raise RuntimeError("Conversation evidence capture failed")
        reference = f"Durable robot-notes evidence checkpoint {digest} (capture: host_normalized)."
        if self._config.native_tools:
            reference += f' Explicit inspection: robotnotes_evidence(id="{digest}").'
        return reference

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        if not self._client or not self._can_write():
            return
        title = self._session_id or "unknown-session"
        content = build_transcript(messages, session_id=title, actor=self._config.actor)
        if self._outbox:
            self._enqueue_automatic({"kind": "transcript", "title": title, "path": self._conversations_path(), "content": content,
                                     "metadata": {"session_id": self._session_id} if self._session_id else {}})
            return
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
        self._evidence_lineage = {"parent_session_id": parent_session_id,
                                  "reset": reset, "rewound": rewound}
        self._evidence_session_lineage[self._session_id] = self._evidence_lineage
        self._recall_cache.clear()
        self._health = MemoryHealth()

    def _conversations_path(self) -> str:
        return f"{CONVERSATIONS_ROOT}/{_sanitize_actor(self._config.actor)}"

    def on_memory_write(
        self, action: str, target: str, content: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        """Mirror committed entries or submit their precise curated correction for review."""
        if not self._client or not self._can_write():
            return
        note = self._config.user_note if target == "user" else self._config.memory_note
        operation = {"kind": "mirror", "note": note, "action": action, "content": content, "metadata": metadata or {}}
        if self._outbox:
            self._enqueue_automatic(operation)
            return
        self._immediate_write(operation, "mirror")

    def _immediate_write(self, operation, name):
        health = self._health
        generation = health.begin(name)
        try:
            for attempt in range(3):
                try:
                    result = self._deliver_automatic(self._prepare_automatic(operation))
                    break
                except ClientError as exc:
                    if not exc.version_conflict or attempt == 2:
                        raise
        except ClientError as exc:
            state = "needs_review" if exc.code == "correction_requires_review" else "failed"
            health.finish(name, generation, state, exc.code if state == "needs_review" else exc.kind.name.lower())
            log = logger.debug if exc.kind is ErrorKind.CIRCUIT_OPEN else logger.warning
            log("robot_notes: automatic write failed (%s)", exc.kind.name.lower())
        else:
            health.finish(name, generation, self._write_outcome(result), source_unknown=result.get("source_unknown"))

    def _overwrite_note(self, *, title: str, path: str, content: str, create_if_missing: bool = True) -> None:
        if not create_if_missing and self._client.find_note_by_title(title, path=path) is None:
            return
        metadata = {"session_id": self._session_id} if self._session_id else {}
        self._immediate_write({"kind": "transcript", "title": title, "path": path,
                               "content": content, "metadata": metadata}, "transcript")

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
                "description": "robot-notes API key or REST OAuth access token",
                "required": True,
                "secret": True,
                "env_var": "ROBOT_NOTES_API_KEY",
            },
            {"key": "vault_id", "description": "Vault ID (blank uses default)", "required": False, "type": "text"},
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        existing = RobotNotesConfig.load(hermes_home)
        RobotNotesConfig.create(
            base_url=str(values.get("base_url", "")),
            actor=str(values.get("actor") or existing.actor),
            evidence_archive=values.get("evidence_archive", existing.evidence_archive),
            evidence_retention_days=values.get("evidence_retention_days", existing.evidence_retention_days),
            native_tools=values.get("native_tools", existing.native_tools),
            durable_writes=values.get("durable_writes", existing.durable_writes),
            vault_id=str(values.get("vault_id", existing.vault_id) or "default"),
            memory_scope=values.get("memory_scope", existing.memory_scope),
            user_id=values.get("user_id", existing.user_id),
            agent_id=values.get("agent_id", existing.agent_id),
            shared_memory_path=values.get("shared_memory_path", existing.shared_memory_path),
            recall_path=values.get("recall_path", existing.recall_path),
            recall_max_bytes=values.get("recall_max_bytes", existing.recall_max_bytes),
            recall_expand_chars=values.get("recall_expand_chars", existing.recall_expand_chars),
        ).save(hermes_home)



def _tool_error_payload(exc: ClientError, tool_name: str) -> Dict[str, Any]:
    """Builds the JSON error body ``handle_tool_call`` returns to the model: the
    server's own ``code``/``message``/``details`` when it sent them (both the
    nested API.md envelope and the flat notes-route shape are already folded
    into ``exc`` by ``RobotNotesClient``), falling back to a kind-derived code
    and this exception's own message when it didn't (e.g. a network error that
    never reached the server). A ``PATH_CONFLICT`` on ``robotnotes_remember``
    gets a message steering the model to search/append instead of retrying the
    same create."""
    code = exc.code or _FALLBACK_ERROR_CODES.get(exc.kind, "error")
    message = exc.server_message or str(exc)
    if exc.path_conflict and tool_name == "robotnotes_remember":
        message = _PATH_CONFLICT_REMEMBER_MESSAGE
    return {"error": code, "message": message, "details": exc.details}
