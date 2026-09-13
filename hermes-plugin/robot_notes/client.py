"""Thin REST client for a robot-notes workspace: bearer-key + X-Actor auth over
the existing /notes and /search endpoints, no MCP framing involved."""

from __future__ import annotations

from enum import Enum, auto
from typing import Any, Callable, Dict, List, Optional

import httpx


class ErrorKind(Enum):
    NOT_FOUND = auto()
    VERSION_CONFLICT = auto()
    NETWORK_ERROR = auto()
    OTHER = auto()


class ClientError(Exception):
    """A robot-notes call failed for exactly one ``kind`` of reason."""

    def __init__(self, message: str, *, kind: ErrorKind = ErrorKind.OTHER):
        super().__init__(message)
        self.kind = kind

    @property
    def not_found(self) -> bool:
        return self.kind is ErrorKind.NOT_FOUND

    @property
    def version_conflict(self) -> bool:
        return self.kind is ErrorKind.VERSION_CONFLICT

    @property
    def network_error(self) -> bool:
        return self.kind is ErrorKind.NETWORK_ERROR


class RobotNotesClient:
    def __init__(self, *, base_url: str, api_key: str, actor: str, timeout: float = 10.0):
        headers = {"Authorization": f"Bearer {api_key}", "X-Actor": actor}
        self._http = httpx.Client(base_url=base_url.rstrip("/"), headers=headers, timeout=timeout)

    def close(self) -> None:
        self._http.close()

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        try:
            response = self._http.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise ClientError(f"{method} {path} failed: {exc}", kind=ErrorKind.NETWORK_ERROR) from exc

        if response.status_code == 404:
            raise ClientError(f"{method} {path}: not found", kind=ErrorKind.NOT_FOUND)
        if response.status_code == 409:
            raise ClientError(f"{method} {path}: version conflict", kind=ErrorKind.VERSION_CONFLICT)
        if response.status_code >= 400:
            raise ClientError(f"{method} {path}: HTTP {response.status_code}")
        return response

    def search(self, query: str, *, limit: int = 20) -> List[Dict[str, Any]]:
        response = self._request("GET", "/search", params={"q": query, "limit": limit})
        return response.json().get("items", [])

    def get_note(self, note_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/notes/{note_id}").json()

    def find_note_by_title(self, title: str, *, path: str) -> Optional[Dict[str, Any]]:
        """A list-endpoint scan, not a lookup by content: the item it returns already
        carries ``version``, so callers that only overwrite (not append) can write
        straight from it without an extra ``get_note`` round trip."""
        response = self._request("GET", "/notes", params={"path": path, "limit": 200})
        for item in response.json().get("items", []):
            if item.get("title") == title:
                return item
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
        before the first attempt. On a lost version race, re-reads only the version
        (not the content, which this caller doesn't need) and retries."""
        current_version = version
        last_error: Optional[ClientError] = None
        for _ in range(max_attempts):
            try:
                return self.update_note(note_id, version=current_version, content=content)
            except ClientError as exc:
                if not exc.version_conflict:
                    raise
                last_error = exc
                current_version = self.get_note(note_id)["version"]
        raise last_error

    def append_note_with_retry(
        self, note_id: str, *, build_content: Callable[[str], str], max_attempts: int = 3
    ) -> Dict[str, Any]:
        """Read-modify-write with retry on a lost version race, mirroring robot-notes'
        own ``append_to_note`` semantics (read, write, retry up to 3x on conflict).
        Use this only when ``build_content`` needs the note's current content —
        callers that overwrite with fixed content should use ``write_note_with_retry``
        instead and skip the read entirely."""
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
