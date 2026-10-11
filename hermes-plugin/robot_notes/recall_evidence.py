from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from typing import Any

_MARK = re.compile(r"</?mark>")
_HEADER = "Relevant notes from robot-notes:\n"


def passage(content: str, snippet: str, max_chars: int) -> str:
    """Expand search evidence within a character limit, including tail matches."""
    anchor = _MARK.sub("", snippet).strip("… \n")
    match = re.search(re.escape(anchor), content, re.IGNORECASE) if anchor else None
    position = match.start() if match else -1
    if position < 0:
        matches = re.findall(r"<mark>(.*?)</mark>", snippet)
        anchor = max(matches, key=len, default="")
        match = re.search(re.escape(anchor), content, re.IGNORECASE) if anchor else None
        position = match.start() if match else 0
    position = max(0, position)
    start = max(0, position - max(0, max_chars - len(anchor)) // 2)
    return content[start : start + max_chars]


def evidence_context(
    items: Sequence[Mapping[str, Any]],
    *,
    max_bytes: int,
    expand_chars: int,
    load_note: Callable[[str], Mapping[str, Any]] | None = None,
) -> tuple[str, int]:
    """Format evidence and source metadata under a total UTF-8 byte budget."""
    context = _HEADER
    count = 0
    for item in items:
        if len(context.encode("utf-8")) >= max_bytes:
            break
        note = item
        snippet = item.get("snippet", "")
        if expand_chars and load_note is not None:
            note = load_note(item["id"])
            body = passage(note.get("content", ""), snippet, expand_chars)
        else:
            body = _MARK.sub("", snippet)
        title = " ".join(note.get("title", "").splitlines())
        source = (
            f"- {title} (id: {item['id']}, {note.get('path', '')}, "
            f"updated: {note.get('updated_at', 'unknown')}): "
        )
        separator = "\n" if count else ""
        remaining = max_bytes - len((context + separator + source).encode("utf-8"))
        if remaining <= 0:
            continue
        bounded = body.encode("utf-8")[:remaining].decode("utf-8", errors="ignore")
        if not bounded:
            continue
        context += separator + source + bounded
        count += 1
    return (context, count) if count else ("", 0)


def narrow_paths(
    roots: Sequence[str | None], task_path: str | None
) -> tuple[str | None, ...]:
    """Intersect task scope with configured roots without widening identity scope."""
    if task_path is None:
        return tuple(roots)
    paths = []
    for root in roots:
        if root is None or task_path == root or task_path.startswith(root + "/"):
            paths.append(task_path)
        elif root.startswith(task_path + "/"):
            paths.append(root)
    return tuple(dict.fromkeys(paths))
