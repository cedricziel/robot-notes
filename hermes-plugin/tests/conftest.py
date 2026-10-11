import pytest

from robot_notes.client import ClientError, RobotNotesClient


@pytest.fixture(autouse=True)
def legacy_permission_endpoints(request, monkeypatch):
    legacy_modules = {
        "test_provider.py",
        "test_durable_writes.py",
        "test_memory_scope.py",
        "test_health.py",
        "test_memory_manager_contract.py",
    }
    if request.path.name not in legacy_modules:
        return

    def unsupported_permissions(self, **kwargs):
        raise ClientError("Legacy fixture has no permissions endpoint", status=404)

    monkeypatch.setattr(
        RobotNotesClient, "get_note_permissions", unsupported_permissions
    )
