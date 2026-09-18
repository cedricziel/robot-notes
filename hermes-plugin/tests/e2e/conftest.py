"""Fixtures for the hermes-plugin end-to-end suite.

Every test under ``tests/e2e/`` talks to a real, running robot-notes server
instead of mocking HTTP with respx. The whole directory is opt-in: it is
skipped (not collected-out, actually *skipped* so `python -m pytest` still
reports it) unless both ``ROBOT_NOTES_E2E_BASE_URL`` and
``ROBOT_NOTES_E2E_API_KEY`` are set. Select it explicitly with
``python -m pytest -m e2e`` once the server is up — see
``make test-hermes-plugin-e2e`` and the ``e2e`` CI job for how those two
pieces (server + env vars) get wired together.

Deliberately separate from ``ROBOT_NOTES_BASE_URL`` / ``ROBOT_NOTES_API_KEY``
(no ``_E2E_`` infix), which is what the provider config and the Claude hook
read at runtime: keeping the names distinct means exporting the e2e vars in a
dev shell can never accidentally make an unrelated hermes/hook process talk
to the test server.
"""

from __future__ import annotations

import os
from typing import Optional

import pytest

from robot_notes.client import RobotNotesClient

BASE_URL_ENV = "ROBOT_NOTES_E2E_BASE_URL"
API_KEY_ENV = "ROBOT_NOTES_E2E_API_KEY"


def _missing_reason() -> Optional[str]:
    if not os.environ.get(BASE_URL_ENV):
        return f"{BASE_URL_ENV} is not set"
    if not os.environ.get(API_KEY_ENV):
        return f"{API_KEY_ENV} is not set"
    return None


@pytest.fixture(autouse=True, scope="session")
def _require_e2e_server():
    """Skips every test in this directory unless a live server is configured.

    An autouse fixture (rather than a collection-time filter) is what makes
    `python -m pytest` with no env report these as *skipped* instead of just
    silently absent, per the issue's acceptance criteria.
    """
    reason = _missing_reason()
    if reason:
        pytest.skip(f"e2e: {reason} (see hermes-plugin/robot_notes/README.md)")


@pytest.fixture(scope="session")
def e2e_base_url() -> str:
    return os.environ[BASE_URL_ENV].rstrip("/")


@pytest.fixture(scope="session")
def e2e_api_key() -> str:
    return os.environ[API_KEY_ENV]


@pytest.fixture
def e2e_client(e2e_base_url, e2e_api_key):
    """A RobotNotesClient pointed at the live e2e server, closed after the test."""
    client = RobotNotesClient(base_url=e2e_base_url, api_key=e2e_api_key, actor="hermes-e2e")
    try:
        yield client
    finally:
        client.close()
