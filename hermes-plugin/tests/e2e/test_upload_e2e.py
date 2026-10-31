"""``robotnotes_upload_file`` against a live server: the bytes land in the vault
unchanged, and a second upload under the same name is refused, not overwritten."""

from __future__ import annotations

import json
import uuid

import httpx
import pytest

from robot_notes import RobotNotesProvider

pytestmark = pytest.mark.e2e


def test_upload_lands_the_file_and_refuses_a_duplicate(tmp_path, monkeypatch, e2e_base_url, e2e_api_key):
    exports = tmp_path / "exports"
    exports.mkdir()
    payload = bytes(range(256)) * 64
    (exports / "chart.png").write_bytes(payload)
    home = tmp_path / "home"
    home.mkdir()
    (home / "robot_notes.json").write_text(json.dumps({
        "base_url": e2e_base_url, "actor": "hermes-e2e", "upload_roots": [str(exports)]}), encoding="utf-8")
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", e2e_api_key)
    folder = f"e2e-upload-{uuid.uuid4().hex[:12]}"

    provider = RobotNotesProvider()
    provider.initialize(f"e2e-session-{uuid.uuid4().hex[:12]}", hermes_home=str(home))
    try:
        args = {"local_path": str(exports / "chart.png"), "path": folder}
        first = json.loads(provider.handle_tool_call("robotnotes_upload_file", args))
        second = json.loads(provider.handle_tool_call("robotnotes_upload_file", args))
    finally:
        provider.shutdown()

    assert first == {"path": folder, "filename": "chart.png", "size": len(payload), "content_type": "image/png"}
    assert second["code"] == "path_conflict"
    stored = httpx.get(f"{e2e_base_url}/notes/files/{folder}/chart.png",
                       headers={"Authorization": f"Bearer {e2e_api_key}"})
    assert stored.status_code == 200
    assert stored.content == payload
