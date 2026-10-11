from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Optional
from urllib.parse import urlparse


@dataclass(frozen=True)
class BlockEditPlan:
    operations: list[dict]
    state: str
    reason: Optional[str] = None


def validate_references(raw) -> list[dict]:
    if not isinstance(raw, list):
        raise ValueError("Evidence references must be a list")
    result = []
    seen = set()
    for value in raw:
        if not isinstance(value, dict):
            raise ValueError("Evidence reference must be an object")
        kind = value.get("kind")
        if not isinstance(kind, str):
            raise ValueError("Invalid evidence reference kind")
        strings = {
            "note_revision": ("note_id",),
            "block_revision": ("note_id", "block_id"),
            "archive": ("digest",),
            "conversation": ("session_id",),
            "url": ("url",),
            "unknown": ("reason",),
        }.get(kind)
        if strings is None:
            raise ValueError("Unsupported evidence reference kind")
        integers = (
            ("version", "block_revision")
            if kind == "block_revision"
            else (("version",) if kind == "note_revision" else ())
        )
        optional = (
            ("turn_id", "tool_call_id", "task_id") if kind == "conversation" else ()
        )
        if set(value) - {"kind", *strings, *integers, *optional}:
            raise ValueError("Unsupported evidence reference field")
        if any(
            not isinstance(value.get(key), str) or not value[key].strip()
            for key in strings
        ):
            raise ValueError("Missing evidence source identifier")
        if any(type(value.get(key)) is not int or value[key] < 1 for key in integers):
            raise ValueError("Invalid evidence source revision")
        if any(
            key in value and (not isinstance(value[key], str) or not value[key].strip())
            for key in optional
        ):
            raise ValueError("Invalid evidence lineage identifier")
        if kind == "archive" and not re.fullmatch(r"[a-f0-9]{64}", value["digest"]):
            raise ValueError("Invalid evidence archive digest")
        if kind == "url":
            url = urlparse(value["url"])
            if url.scheme not in {"http", "https"} or not url.netloc:
                raise ValueError("Invalid evidence URL")
        key = json.dumps(value, sort_keys=True)
        if key not in seen:
            result.append(dict(value))
            seen.add(key)
    return result


def source_references(metadata: Optional[dict] = None) -> list[dict]:
    """Keep supplied source coordinates; missing callback lineage stays unknown."""
    metadata = metadata or {}
    refs = validate_references(metadata.get("evidence_refs", []))
    if isinstance(metadata.get("session_id"), str) and metadata["session_id"].strip():
        lineage = {"kind": "conversation", "session_id": metadata["session_id"]}
        for key in ("turn_id", "tool_call_id", "task_id"):
            if isinstance(metadata.get(key), str) and metadata[key].strip():
                lineage[key] = metadata[key]
        refs = validate_references([*refs, lineage])
    return refs or [{"kind": "unknown", "reason": "source_not_recorded"}]


def _accepted_blocks(note, mapping):
    if (
        not isinstance(note, dict)
        or not isinstance(mapping, dict)
        or not isinstance(note.get("content"), str)
    ):
        raise ValueError("block_map_stale")
    body = note["content"]
    raw = body.encode("utf-16-le")
    if (
        mapping.get("id") != note["id"]
        or mapping.get("version") != note["version"]
        or mapping.get("offset_encoding") != "utf-16"
        or mapping.get("content_hash") != hashlib.sha256(body.encode()).hexdigest()
        or type(mapping.get("version")) is not int
        or type(note["version"]) is not int
        or note["version"] < 1
    ):
        raise ValueError("block_map_stale")
    if any(
        not isinstance(mapping.get(key, []), list)
        or any(not isinstance(value, str) for value in mapping.get(key, []))
        for key in ("changed_ids", "retired_ids", "ambiguous_ids")
    ):
        raise ValueError("block_map_stale")
    result = []
    ids = set()
    previous_end = 0
    for block in mapping["blocks"]:
        start, end = block["start"], block["end"]
        if (
            type(start) is not int
            or type(end) is not int
            or not 0 <= start < end <= len(raw) // 2
            or start < previous_end
            or not isinstance(block["id"], str)
            or not block["id"]
            or block["id"] in ids
            or type(block["revision"]) is not int
            or block["revision"] < 1
        ):
            raise ValueError("block_map_stale")
        text = raw[start * 2 : end * 2].decode("utf-16-le")
        if block["hash"] != hashlib.sha256(text.encode()).hexdigest():
            raise ValueError("block_map_stale")
        result.append(
            {
                **block,
                "start": len(raw[: start * 2].decode("utf-16-le")),
                "end": len(raw[: end * 2].decode("utf-16-le")),
            }
        )
        ids.add(block["id"])
        previous_end = end
    return result


def compile_block_edit(
    note: dict,
    mapping: dict,
    desired: str,
    *,
    evidence_refs: Optional[list[dict]] = None,
) -> BlockEditPlan:
    """Express exact edits with accepted anchors, refusing edits to unmapped gaps."""
    try:
        blocks = _accepted_blocks(note, mapping)
    except (KeyError, TypeError, ValueError, UnicodeError):
        return BlockEditPlan([], "needs_review", "block_map_stale")
    body = note["content"]
    if desired == body:
        return BlockEditPlan([], "unchanged")
    refs = validate_references(evidence_refs or [])
    edits = {}
    terminal = []
    for kind, start, end, new_start, new_end in SequenceMatcher(
        None, body, desired, autojunk=False
    ).get_opcodes():
        if kind == "equal":
            continue
        candidates = [
            block for block in blocks if block["start"] <= start <= end <= block["end"]
        ]
        if candidates:
            block = candidates[0]
            if block["id"] in mapping.get("ambiguous_ids", []):
                return BlockEditPlan([], "needs_review", "ambiguous_block")
            edits.setdefault(block["id"], []).append(
                (start, end, desired[new_start:new_end])
            )
        elif kind == "insert" and start == len(body):
            terminal.append(desired[new_start:new_end])
        else:
            return BlockEditPlan([], "needs_review", "structural_edit_required")
    operations = []
    for block in blocks:
        changes = edits.get(block["id"])
        if not changes:
            continue
        text = body[block["start"] : block["end"]]
        for start, end, replacement in reversed(changes):
            text = (
                text[: start - block["start"]]
                + replacement
                + text[end - block["start"] :]
            )
        operation = {
            "type": "replace" if text else "delete",
            "block_id": block["id"],
            "expected_revision": block["revision"],
        }
        if text:
            operation.update(
                text=text,
                supersedes=[
                    {
                        "kind": "block_revision",
                        "note_id": note["id"],
                        "version": note["version"],
                        "block_id": block["id"],
                        "block_revision": block["revision"],
                    }
                ],
            )
            if refs:
                operation["evidence_refs"] = refs
        operations.append(operation)
    if terminal:
        anchor = blocks[-1] if blocks else None
        if anchor and anchor["id"] in mapping.get("ambiguous_ids", []):
            return BlockEditPlan([], "needs_review", "ambiguous_block")
        operation = {
            "type": "insert_after",
            "block_id": anchor["id"] if anchor else None,
            "expected_revision": anchor["revision"] if anchor else None,
            "text": "".join(terminal),
        }
        if refs:
            operation["evidence_refs"] = refs
        operations.append(operation)
    return BlockEditPlan(operations, "proposable")
