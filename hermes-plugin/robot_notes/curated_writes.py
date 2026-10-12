from __future__ import annotations

from typing import Optional
from uuid import uuid4

from .client import ClientError, ErrorKind
from .correction_proposals import compile_block_edit


def read_note_for_write(client, note_id):
    note = client.get_note(note_id)
    if (
        not isinstance(note, dict)
        or note.get("id") != note_id
        or type(note.get("version")) is not int
        or note["version"] < 1
        or not all(
            isinstance(note.get(key), str) for key in ("content", "title", "path")
        )
        or ("properties" in note and not isinstance(note["properties"], dict))
    ):
        raise ClientError("Malformed accepted source response", code="invalid_response")
    return note


def permissions_for_target(client, current, path, title, curated_intent):
    observed = current and (
        current.get("curated") is True
        or (current.get("properties") or {}).get("curated") in (True, "true")
    )
    try:
        return (
            client.get_note_permissions(note_id=current["id"])
            if current
            else client.get_note_permissions(path=path, title=title)
        )
    except ClientError as exc:
        if exc.status not in (404, 405):
            raise
        if curated_intent or observed:
            raise ClientError(
                "Curated destination requires the permissions and proposal API",
                code="curated_api_unavailable",
            ) from exc
        return None


def prepare_write(
    client,
    *,
    current: Optional[dict],
    title: str,
    path: str,
    desired: str,
    refs: list,
    curated_intent: bool = False,
    delete_note: bool = False,
    idempotency_key: Optional[str] = None,
) -> dict:
    """Freeze an accepted write or a proposal; runtime agents always propose curated edits."""
    policy = permissions_for_target(client, current, path, title, curated_intent)
    curated = curated_intent or (policy is not None and policy["curated"])
    base = {
        "schema": 2,
        "title": title,
        "path": path,
        "content": desired,
        "before": current["content"] if current else None,
        "evidence_refs": refs,
        "delete_note": delete_note,
        "curated_intent": curated_intent,
    }
    if current:
        base.update(id=current["id"], version=current["version"])
    base["idempotency_key"] = (
        idempotency_key if idempotency_key is not None else f"hermes-{uuid4().hex}"
    )
    if not curated:
        return {**base, "route": "accepted"}
    if policy is not None and "propose" not in policy["allowed_actions"]:
        raise ClientError(
            "Proposal submission is not permitted",
            kind=ErrorKind.AUTH,
            status=403,
            code="proposal_denied",
        )
    if current is None:
        return {**base, "route": "proposal_create"}
    if delete_note:
        operations = [{"type": "delete_note"}]
    else:
        mapping = client.get_note_blocks(current["id"])
        if (
            mapping["version"] != current["version"]
            or mapping["content"] != current["content"]
        ):
            raise ClientError(
                "Accepted source changed during preparation",
                kind=ErrorKind.VERSION_CONFLICT,
                status=409,
            )
        plan = compile_block_edit(current, mapping, desired, evidence_refs=refs)
        if plan.state == "unchanged":
            return {**base, "route": "noop"}
        if plan.state != "proposable":
            raise ClientError(
                "Correction needs precise block review",
                code="correction_requires_review",
                details={"reason": plan.reason},
            )
        operations = plan.operations
    return {**base, "route": "proposal", "operations": operations}


def ordinary_outcome(result):
    if not isinstance(result, dict):
        raise ClientError(
            "Malformed accepted write acknowledgement", code="invalid_response"
        )
    return {**result, "source_unknown": True}


def deliver_write(client, prepared: dict) -> dict:
    """Replay frozen proposals with the same key; accepted writes check exact versions."""
    route = prepared["route"]
    if route == "noop":
        return {"accepted": False, "state": "unchanged"}
    if route == "proposal":
        return client.propose_note_update(
            prepared["id"],
            base_version=prepared["version"],
            operations=prepared["operations"],
            evidence_refs=prepared["evidence_refs"],
            idempotency_key=prepared["idempotency_key"],
        )
    if route == "proposal_create":
        return client.propose_note_create(
            path=prepared["path"],
            title=prepared["title"],
            content=prepared["content"],
            evidence_refs=prepared["evidence_refs"],
            idempotency_key=prepared["idempotency_key"],
            curated_intent=True,
        )
    if "id" in prepared:
        current = read_note_for_write(client, prepared["id"])
        if (
            not prepared["delete_note"]
            and current.get("content") == prepared["content"]
        ):
            return {
                "accepted": True,
                "state": "unchanged",
                "note_id": prepared["id"],
                "source_unknown": True,
            }
        if current["version"] != prepared["version"]:
            raise ClientError(
                "Prepared accepted source changed",
                kind=ErrorKind.VERSION_CONFLICT,
                status=409,
            )
        fresh = prepare_write(
            client,
            current=current,
            title=prepared["title"],
            path=prepared["path"],
            desired=prepared["content"],
            refs=prepared["evidence_refs"],
            delete_note=prepared["delete_note"],
            curated_intent=prepared["curated_intent"],
            idempotency_key=prepared["idempotency_key"],
        )
        if fresh["route"] != "accepted":
            raise ClientError(
                "Prepared destination became curated",
                kind=ErrorKind.AUTH,
                status=403,
                code="curated_policy_changed",
            )
        if prepared["delete_note"]:
            return ordinary_outcome(client.delete_note(prepared["id"]))
        return ordinary_outcome(
            client.update_note(
                prepared["id"], version=prepared["version"], content=prepared["content"]
            )
        )
    policy = permissions_for_target(
        client, None, prepared["path"], prepared["title"], prepared["curated_intent"]
    )
    if policy is not None and policy["curated"]:
        raise ClientError(
            "Prepared destination became curated",
            kind=ErrorKind.AUTH,
            status=403,
            code="curated_policy_changed",
        )
    existing = client.find_note_by_title(prepared["title"], path=prepared["path"])
    if existing:
        current = read_note_for_write(client, existing["id"])
        if current["title"] != prepared["title"] or current["path"] != prepared["path"]:
            raise ClientError(
                "Prepared destination moved", kind=ErrorKind.PATH_CONFLICT
            )
        if current.get("content") == prepared["content"]:
            return {
                "accepted": True,
                "state": "unchanged",
                "note_id": current["id"],
                "source_unknown": True,
            }
        raise ClientError("Prepared destination changed", kind=ErrorKind.PATH_CONFLICT)
    return ordinary_outcome(
        client.create_note(
            title=prepared["title"], path=prepared["path"], content=prepared["content"]
        )
    )
