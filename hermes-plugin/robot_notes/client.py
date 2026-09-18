"""Thin REST client for a robot-notes workspace: bearer-key + X-Actor auth over
the existing /notes and /search endpoints, no MCP framing involved."""

from __future__ import annotations

from enum import Enum, auto
from typing import Any, Callable, Dict, List, Optional

import httpx


class ErrorKind(Enum):
    NOT_FOUND = auto()
    VERSION_CONFLICT = auto()
    PATH_CONFLICT = auto()
    LOCKED = auto()
    AUTH = auto()
    NETWORK_ERROR = auto()
    OTHER = auto()


class ClientError(Exception):
    """A robot-notes call failed for exactly one ``kind`` of reason.

    Carries whatever the server's error body actually said, on top of the
    ``kind`` classification: ``code`` (the error string/code, e.g.
    ``"path_conflict"``), ``server_message`` (a human-readable message, when
    the server sent one), ``details`` (everything else the body carried —
    ``current_version``/``current_content``, a lock ``holder``, etc.) and the
    HTTP ``status``.
    """

    def __init__(
        self,
        message: str,
        *,
        kind: ErrorKind = ErrorKind.OTHER,
        code: Optional[str] = None,
        server_message: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
        status: Optional[int] = None,
    ):
        super().__init__(message)
        self.kind = kind
        self.code = code
        self.server_message = server_message
        self.details: Dict[str, Any] = details or {}
        self.status = status

    @property
    def not_found(self) -> bool:
        return self.kind is ErrorKind.NOT_FOUND

    @property
    def version_conflict(self) -> bool:
        return self.kind is ErrorKind.VERSION_CONFLICT

    @property
    def path_conflict(self) -> bool:
        return self.kind is ErrorKind.PATH_CONFLICT

    @property
    def locked(self) -> bool:
        return self.kind is ErrorKind.LOCKED

    @property
    def auth_error(self) -> bool:
        return self.kind is ErrorKind.AUTH

    @property
    def network_error(self) -> bool:
        return self.kind is ErrorKind.NETWORK_ERROR

    @property
    def current_version(self) -> Optional[int]:
        """The version the server says is current, from either envelope shape
        (``details.current_version`` or the flat route's ``details.current.version``)
        — lets a caller retry a lost race without an extra ``GET``."""
        if "current_version" in self.details:
            return self.details["current_version"]
        current = self.details.get("current")
        if isinstance(current, dict):
            return current.get("version")
        return None

    @property
    def current_content(self) -> Optional[str]:
        if "current_content" in self.details:
            return self.details["current_content"]
        current = self.details.get("current")
        if isinstance(current, dict):
            return current.get("content")
        return None

    @property
    def lock_holder(self) -> Optional[str]:
        lock = self.details.get("lock")
        if isinstance(lock, dict):
            return lock.get("holder")
        return None


# Status codes whose meaning doesn't depend on the error ``code`` in the body.
_STATUS_KINDS: Dict[int, ErrorKind] = {
    404: ErrorKind.NOT_FOUND,
    423: ErrorKind.LOCKED,
    401: ErrorKind.AUTH,
    403: ErrorKind.AUTH,
}

# 409 is overloaded: `POST /notes` and `PUT /notes/{id}` both use it for two
# different conflicts, distinguished only by the error code in the body.
_CONFLICT_CODE_KINDS: Dict[str, ErrorKind] = {
    "version_conflict": ErrorKind.VERSION_CONFLICT,
    "path_conflict": ErrorKind.PATH_CONFLICT,
}


class RobotNotesClient:
    def __init__(self, *, base_url: str, api_key: str, actor: str, timeout: float = 10.0):
        headers = {"Authorization": f"Bearer {api_key}", "X-Actor": actor}
        self._http = httpx.Client(base_url=base_url.rstrip("/"), headers=headers, timeout=timeout)

    def close(self) -> None:
        self._http.close()

    @staticmethod
    def _parse_error_body(response: httpx.Response) -> tuple[Optional[str], Optional[str], Dict[str, Any]]:
        """Parses a non-2xx body into ``(code, message, details)``, accepting either
        the nested envelope documented in ``server/API.md``
        (``{"error": {"code", "message", "details"}}``) or the flat shape the
        notes routes actually send today (``{"error": "path_conflict", ...}``,
        with any sibling keys — ``current``, ``lock``, etc. — folded into
        ``details`` so callers can reach them uniformly)."""
        try:
            body = response.json()
        except ValueError:
            return None, None, {}
        if not isinstance(body, dict):
            return None, None, {}

        error = body.get("error")
        if isinstance(error, dict):
            code = error.get("code")
            message = error.get("message")
            details = error.get("details")
            return code, message, dict(details) if isinstance(details, dict) else {}
        if isinstance(error, str):
            details = {k: v for k, v in body.items() if k not in ("error", "message")}
            return error, body.get("message"), details
        return None, None, {}

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        try:
            response = self._http.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise ClientError(f"{method} {path} failed: {exc}", kind=ErrorKind.NETWORK_ERROR) from exc

        if response.status_code < 400:
            return response

        status = response.status_code
        code, server_message, details = self._parse_error_body(response)

        if status == 409 and code in _CONFLICT_CODE_KINDS:
            kind = _CONFLICT_CODE_KINDS[code]
        else:
            kind = _STATUS_KINDS.get(status, ErrorKind.OTHER)

        message = server_message or code or f"HTTP {status}"
        raise ClientError(
            f"{method} {path}: {message}",
            kind=kind,
            code=code,
            server_message=server_message,
            details=details,
            status=status,
        )

    def search(self, query: str, *, limit: int = 20) -> List[Dict[str, Any]]:
        response = self._request("GET", "/search", params={"q": query, "limit": limit})
        return response.json().get("items", [])

    def list_notes(
        self, *, path: Optional[str] = None, limit: int = 50, after: Optional[str] = None
    ) -> Dict[str, Any]:
        """Paginated note metadata (no content) via ``GET /notes`` — the only way to
        enumerate every note in the workspace. ``search`` cannot do this: it is
        keyword search, not a wildcard, so it has no query that means "everything".
        Returns the raw ``{"items": [...], "next_cursor": ...}`` page; pass a
        result's ``next_cursor`` back as ``after`` to fetch the next page."""
        params: Dict[str, Any] = {"limit": limit}
        if path is not None:
            params["path"] = path
        if after is not None:
            params["after"] = after
        response = self._request("GET", "/notes", params=params)
        return response.json()

    def get_note(self, note_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/notes/{note_id}").json()

    def find_note_by_title(self, title: str, *, path: str) -> Optional[Dict[str, Any]]:
        """Looks up a note by exact title within ``path``. The item returned already
        carries ``version``, so callers that only overwrite (not append) can write
        straight from it without an extra ``get_note`` round trip.

        Tries the server's dedicated ``title`` filter first (a single request);
        that filter may not exist on every deployed server yet, so an HTTP 400
        response is treated as "unsupported" and triggers a fall back to a full
        cursor scan of the folder instead of being raised. Any other error from
        the filter attempt (network failure, 5xx, etc.) is not swallowed."""
        try:
            response = self._request("GET", "/notes", params={"path": path, "title": title, "limit": 1})
        except ClientError as exc:
            if exc.status != 400:
                raise
        else:
            items = response.json().get("items", [])
            return items[0] if items else None

        return self._find_note_by_title_scan(title, path=path)

    def _find_note_by_title_scan(self, title: str, *, path: str) -> Optional[Dict[str, Any]]:
        """Pages through every note in ``path`` via ``next_cursor`` looking for an
        exact title match, used when the server has no ``title`` filter to lean
        on. Sorted most-recently-updated first so the common case — a session
        resumed shortly after it left off — is found on the very first page
        rather than requiring the whole folder to be walked."""
        cursor: Optional[str] = None
        while True:
            params: Dict[str, Any] = {"path": path, "limit": 200, "sort": "updated_desc"}
            if cursor is not None:
                params["after"] = cursor
            response = self._request("GET", "/notes", params=params)
            payload = response.json()
            for item in payload.get("items", []):
                if item.get("title") == title:
                    return item
            cursor = payload.get("next_cursor")
            if not cursor:
                return None

    def create_note(self, *, title: str, content: str = "", path: str = "") -> Dict[str, Any]:
        return self._request("POST", "/notes", json={"title": title, "content": content, "path": path}).json()

    def update_note(
        self, note_id: str, *, version: int, title: Optional[str] = None, content: Optional[str] = None
    ) -> Dict[str, Any]:
        body: Dict[str, Any] = {}
        if title is not None:
            body["title"] = title
        if content is not None:
            body["content"] = content
        response = self._request("PUT", f"/notes/{note_id}", json=body, headers={"If-Match": str(version)})
        return response.json()

    def delete_note(self, note_id: str) -> Dict[str, Any]:
        return self._request("DELETE", f"/notes/{note_id}").json()

    def write_note_with_retry(
        self, note_id: str, *, version: int, content: str, max_attempts: int = 3
    ) -> Dict[str, Any]:
        """Blind overwrite of fixed ``content`` at an already-known ``version`` — no read
        before the first attempt. Retries **only** on ``VERSION_CONFLICT`` — a
        ``PATH_CONFLICT``, ``LOCKED`` or any other kind is a different problem that
        retrying at a fresh version can't fix, so it's raised straight through. On a
        lost version race, this prefers the server's own ``current_version`` (carried
        on the ``409`` body) over an extra ``GET``, and only falls back to reading the
        note when the server didn't say."""
        current_version = version
        last_error: Optional[ClientError] = None
        for _ in range(max_attempts):
            try:
                return self.update_note(note_id, version=current_version, content=content)
            except ClientError as exc:
                if not exc.version_conflict:
                    raise
                last_error = exc
                if exc.current_version is not None:
                    current_version = exc.current_version
                else:
                    current_version = self.get_note(note_id)["version"]
        raise last_error

    def append_note_with_retry(
        self, note_id: str, *, build_content: Callable[[str], str], max_attempts: int = 3
    ) -> Dict[str, Any]:
        """Read-modify-write with retry on a lost version race, mirroring robot-notes'
        own ``append_to_note`` semantics (read, write, retry up to 3x on conflict).
        Retries **only** on ``VERSION_CONFLICT``; a ``PATH_CONFLICT``, ``LOCKED`` or
        any other kind is raised straight through instead, since re-reading and
        rewriting can't fix those. Use this only when ``build_content`` needs the
        note's current content — callers that overwrite with fixed content should use
        ``write_note_with_retry`` instead and skip the read entirely."""
        last_error: Optional[ClientError] = None
        for _ in range(max_attempts):
            note = self.get_note(note_id)
            content = build_content(note.get("content", ""))
            try:
                return self.update_note(note_id, version=note["version"], content=content)
            except ClientError as exc:
                if not exc.version_conflict:
                    raise
                last_error = exc
        raise last_error
