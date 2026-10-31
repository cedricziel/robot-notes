import pytest

from robot_notes import uploads
from robot_notes.client import ClientError
from robot_notes.uploads import open_upload_source


@pytest.fixture
def root(tmp_path):
    exports = tmp_path / "exports"
    exports.mkdir()
    (exports / "report.pdf").write_bytes(b"%PDF")
    (tmp_path / "secret.txt").write_text("outside")
    return exports


def _code(local_path, roots):
    with pytest.raises(ClientError) as raised:
        open_upload_source(str(local_path), roots)
    return raised.value.code


def test_opens_a_regular_file_under_a_root(root):
    with open_upload_source(str(root / "report.pdf"), [str(root)]) as source:
        assert source.read() == b"%PDF"


def test_opens_a_file_in_a_nested_folder(root):
    (root / "2026").mkdir()
    (root / "2026" / "a.png").write_bytes(b"png")

    with open_upload_source(str(root / "2026" / "a.png"), [str(root)]) as source:
        assert source.read() == b"png"


def test_dot_dot_escape_is_denied(root):
    assert _code(root / ".." / "secret.txt", [str(root)]) == "upload_path_denied"


def test_symlink_escape_is_denied(root):
    (root / "link.txt").symlink_to(root.parent / "secret.txt")

    assert _code(root / "link.txt", [str(root)]) == "upload_path_denied"


def test_sibling_with_shared_prefix_is_denied(root):
    sibling = root.parent / "exports-private"
    sibling.mkdir()
    (sibling / "x.txt").write_text("x")

    assert _code(sibling / "x.txt", [str(root)]) == "upload_path_denied"


def test_symlinked_root_still_matches_its_target(root, tmp_path):
    alias = tmp_path / "alias"
    alias.symlink_to(root)

    with open_upload_source(str(root / "report.pdf"), [str(alias)]) as source:
        assert source.read() == b"%PDF"


@pytest.mark.parametrize("local_path", ["report.pdf", "", "missing.pdf", "."])
def test_relative_missing_or_directory_paths_are_invalid(root, local_path):
    target = local_path if local_path in ("report.pdf", "") else str(root / local_path)

    assert _code(target, [str(root)]) == "upload_path_invalid"


def test_host_read_denylist_is_honored(root, monkeypatch):
    monkeypatch.setattr(uploads, "get_read_block_error", lambda path: "blocked credential store")

    assert _code(root / "report.pdf", [str(root)]) == "upload_path_denied"
