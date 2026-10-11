from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class MemoryEditPlan:
    """A complete proposed edit, an idempotent no-op, or an unresolved selector."""

    content: Optional[str]
    state: str
    reason: Optional[str] = None


def _exact_spans(current: str, entry: str) -> list[tuple[int, int]]:
    pattern = r"(?m)(?=^(" + re.escape(entry) + r")(?=\n|$))"
    return [(match.start(1), match.end(1)) for match in re.finditer(pattern, current)]


def _remove_span(current: str, start: int, end: int) -> str:
    if end < len(current) and current[end] == "\n":
        end += 1
    elif start and current[start - 1] == "\n":
        start -= 1
    return current[:start] + current[end:]


def plan_memory_edit(
    current: str, action: str, content: str, metadata: Optional[dict] = None
) -> MemoryEditPlan:
    """Plan an entry edit without appending unresolved corrections.

    Exact committed previous_content takes precedence over a legacy selector.
    Multiline entries require a complete line-bounded span. Ambiguous distinct
    matches and overlapping spans require review instead of a guessed mutation.
    """
    metadata = metadata or {}
    if action not in {"add", "replace", "remove"}:
        return MemoryEditPlan(None, "needs_review", "unsupported_action")
    if action == "replace" and not content.strip():
        return MemoryEditPlan(None, "needs_review", "empty_replacement")
    if action == "add":
        if not content.strip() or re.search(r"(?m)^[^\S\n]*" + re.escape(content.strip()) + r"[^\S\n]*(?=\n|$)", current):
            return MemoryEditPlan(None, "unchanged")
        separator = "" if not current or current.endswith("\n") else "\n"
        return MemoryEditPlan(current + separator + content, "changed")

    if "previous_content" in metadata:
        previous = metadata["previous_content"]
        if not isinstance(previous, str) or not previous.strip():
            return MemoryEditPlan(None, "needs_review", "invalid_previous_content")
        spans = _exact_spans(current, previous)
    else:
        selector = metadata.get("old_text") or (content if action == "remove" else "")
        if not isinstance(selector, str) or not selector.strip():
            return MemoryEditPlan(None, "needs_review", "missing_previous_entry")
        selector = selector.strip()
        spans = _exact_spans(current, selector)
        if not spans and "\n" not in selector:
            lines = [
                (match.start(), match.end(), match.group())
                for match in re.finditer(r"[^\n]+", current)
                if selector in match.group()
            ]
            distinct = {line for _, _, line in lines}
            if len(distinct) > 1:
                return MemoryEditPlan(None, "needs_review", "ambiguous_selector")
            spans = [(start, end) for start, end, _ in lines]

    if not spans:
        if action == "replace" and _exact_spans(current, content):
            return MemoryEditPlan(None, "unchanged")
        if action == "remove":
            return MemoryEditPlan(None, "unchanged")
        return MemoryEditPlan(None, "needs_review", "missing_previous_entry")
    if any(left[1] > right[0] for left, right in zip(spans, spans[1:])):
        return MemoryEditPlan(None, "needs_review", "ambiguous_selector")

    desired = current
    for start, end in reversed(spans):
        desired = (
            _remove_span(desired, start, end)
            if action == "remove"
            else desired[:start] + content + desired[end:]
        )
    return (
        MemoryEditPlan(None, "unchanged")
        if desired == current
        else MemoryEditPlan(desired, "changed")
    )
