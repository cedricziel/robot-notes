"""Readable, bounded session transcripts for the robot-notes memory provider.

``on_session_end`` used to file the raw Hermes message list verbatim: every
role (including ``tool`` and ``system``), list-shaped content rendered with
``str(part)`` (a Python dict repr), and no size bound. This module replaces
that with a transcript that:

- keeps only ``user``/``assistant`` text (string content, or the ``text``
  parts of list-shaped content) and drops everything else: ``tool``/
  ``system`` messages, assistant messages that carry only ``tool_calls``,
  and Hermes' own context-compaction handoff summaries,
- strips the ``<memory-context>...</memory-context>`` block Hermes prepends
  to a user turn with recalled memory (that's recalled memory, not
  something the user said),
- renders a small header (session id, actor, ISO date, turn count) and a
  one-line title derived from the first user message, and
- bounds total size, keeping the head and tail of the conversation with an
  elision marker in between.

The compaction-summary check is a local replica of upstream Hermes'
``agent.context_compressor.is_compaction_summary_message`` (metadata key
``_compressed_summary`` plus the ``SUMMARY_PREFIX``/``LEGACY_SUMMARY_PREFIX``
content markers, and their historical variants, which all share the current
prefix's leading marker text). It is reimplemented here rather than imported
because hermes-agent is an optional dependency of this plugin (see
``_memory_provider_base.py``).
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

# -- Compaction-summary detection (local replica, see module docstring) ----

_COMPRESSED_SUMMARY_METADATA_KEY = "_compressed_summary"
# Current handoff prefix marker. Every historical variant upstream (pre-#80622,
# pre-#69619, the "tools remain fully active" fix, the carveout era) begins
# with this same bracketed marker even though the body text differs, so
# matching on it catches all of them without hard-coding the full prose.
_SUMMARY_PREFIX_MARKER = "[CONTEXT COMPACTION — REFERENCE ONLY]"
_LEGACY_SUMMARY_PREFIX = "[CONTEXT SUMMARY]:"
# A compaction summary merged onto a preserved message carries the handoff
# prefix after this delimiter rather than at the start of the content.
_MERGED_SUMMARY_DELIMITER = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"

# The block Hermes prepends to a user turn with recalled memory
# (agent.memory_manager.build_memory_context_block).
_MEMORY_CONTEXT_RE = re.compile(r"<\s*memory-context\s*>.*?</\s*memory-context\s*>", re.IGNORECASE | re.DOTALL)

MAX_TRANSCRIPT_BYTES = 32 * 1024


def _content_text(content: Any) -> str:
    """Extract plain text from Hermes message content: a string as-is, or the
    ``text`` parts of list-shaped content joined with newlines. Non-text
    parts (``tool_use``, ``tool_result``, images, ...) are dropped."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: List[str] = []
        for part in content:
            if isinstance(part, dict):
                if part.get("type") == "text":
                    text = part.get("text", "")
                    if text:
                        parts.append(text)
            elif isinstance(part, str):
                parts.append(part)
        return "\n".join(parts)
    return ""


def is_compaction_summary_message(message: Dict[str, Any]) -> bool:
    """True for a context-compaction handoff message, by metadata flag or by
    content prefix (current, legacy, and merged-behind-a-delimiter forms)."""
    if message.get(_COMPRESSED_SUMMARY_METADATA_KEY):
        return True
    text = _content_text(message.get("content")).lstrip()
    if _MERGED_SUMMARY_DELIMITER in text:
        text = text.split(_MERGED_SUMMARY_DELIMITER, 1)[1].lstrip()
    return text.startswith((_SUMMARY_PREFIX_MARKER, _LEGACY_SUMMARY_PREFIX))


def _strip_memory_context(text: str) -> str:
    return _MEMORY_CONTEXT_RE.sub("", text).strip()


def _derive_title(text: str, limit: int = 80) -> str:
    stripped = text.strip()
    if not stripped:
        return ""
    first_line = stripped.splitlines()[0].strip()
    if len(first_line) <= limit:
        return first_line
    return first_line[: limit - 1].rstrip() + "…"


def _is_tool_calls_only(message: Dict[str, Any]) -> bool:
    """True for an assistant message whose only payload is tool_calls -- no
    text worth keeping in a human-readable transcript."""
    return bool(message.get("tool_calls")) and not _content_text(message.get("content")).strip()


def _filter_turns(messages: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    """Reduce a raw Hermes message list to the readable turns worth filing."""
    turns: List[Dict[str, str]] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue
        if is_compaction_summary_message(message):
            continue
        if role == "assistant" and _is_tool_calls_only(message):
            continue
        text = _content_text(message.get("content"))
        if role == "user":
            text = _strip_memory_context(text)
        text = text.strip()
        if not text:
            continue
        turns.append({"role": role, "text": text})
    return turns


def _truncate_text(text: str, max_bytes: int) -> str:
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text
    return encoded[:max_bytes].decode("utf-8", errors="ignore").rstrip() + "…"


def _take_within_budget(blocks: List[str], budget: int) -> List[str]:
    """Greedily take leading blocks (in the given order) that fit in *budget*
    bytes, joined with a blank line. If even the first block alone exceeds
    the budget, keep one block truncated to fit rather than keeping none."""
    kept: List[str] = []
    used = 0
    for block in blocks:
        size = len(block.encode("utf-8"))
        joiner = 2 if kept else 0
        if not kept and size > budget:
            return [_truncate_text(block, budget)]
        if used + joiner + size > budget:
            break
        kept.append(block)
        used += joiner + size
    return kept


def _bound_blocks(blocks: List[str]) -> str:
    joined = "\n\n".join(blocks)
    if len(joined.encode("utf-8")) <= MAX_TRANSCRIPT_BYTES:
        return joined

    budget = MAX_TRANSCRIPT_BYTES // 2
    head = _take_within_budget(blocks, budget)
    tail = list(reversed(_take_within_budget(list(reversed(blocks)), budget)))

    if len(head) + len(tail) > len(blocks):
        # Overlap: the head and tail windows reached into each other. Trim
        # the tail back so every kept block is counted once.
        tail = tail[len(head) + len(tail) - len(blocks) :]

    elided = len(blocks) - len(head) - len(tail)
    if elided <= 0:
        return "\n\n".join(head + tail)

    kept_bytes = sum(len(b.encode("utf-8")) for b in head + tail)
    elided_bytes = max(0, len(joined.encode("utf-8")) - kept_bytes)
    marker = f"\n\n… [{elided} turns / {elided_bytes} bytes elided] …\n\n"
    return "\n\n".join(head) + marker + "\n\n".join(tail)


def build_transcript(
    messages: List[Dict[str, Any]],
    *,
    session_id: str,
    actor: str,
    now: Optional[datetime] = None,
) -> str:
    """Build the readable, bounded session-end note body for *messages*."""
    turns = _filter_turns(messages)
    timestamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not turns:
        return (
            "# (empty session)\n\n"
            f"- Session: {session_id}\n"
            f"- Actor: {actor}\n"
            f"- Date: {timestamp}\n"
            "- Turns: 0\n\n"
            "(no user or assistant text in this session)\n"
        )

    first_user = next((t["text"] for t in turns if t["role"] == "user"), turns[0]["text"])
    title = _derive_title(first_user) or "(untitled session)"

    header = (
        f"# {title}\n\n"
        f"- Session: {session_id}\n"
        f"- Actor: {actor}\n"
        f"- Date: {timestamp}\n"
        f"- Turns: {len(turns)}\n\n"
        "---\n\n"
    )

    blocks = [f"**{turn['role']}**: {turn['text']}" for turn in turns]
    return header + _bound_blocks(blocks)
