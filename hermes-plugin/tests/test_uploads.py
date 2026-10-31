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


@pytest.mark.parametrize("local_path", ["report.pdf", ""])
def test_relative_paths_are_invalid(root, local_path):
    assert _code(local_path, [str(root)]) == "upload_path_invalid"


@pytest.mark.parametrize("name", ["missing.pdf", "."])
def test_missing_or_directory_paths_are_invalid(root, name):
    assert _code(root / name, [str(root)]) == "upload_path_invalid"


def test_host_read_denylist_is_honored(root, monkeypatch):
    monkeypatch.setattr(uploads, "get_read_block_error", lambda path: "blocked credential store")

    assert _code(root / "report.pdf", [str(root)]) == "upload_path_denied"


def test_directory_swapped_for_a_symlink_after_the_check_is_refused(root, monkeypatch):
    nested = root / "nested"
    nested.mkdir()
    (nested / "a.txt").write_text("inside")
    outside = root.parent / "outside"
    outside.mkdir()
    (outside / "a.txt").write_text("secret")

    def swap_then_allow(path):
        nested.rename(root / "moved")
        nested.symlink_to(outside)
        return None

    monkeypatch.setattr(uploads, "get_read_block_error", swap_then_allow)

    assert _code(nested / "a.txt", [str(root)]) == "upload_path_invalid"


def test_root_swapped_for_a_symlink_after_the_check_is_refused(root, monkeypatch):
    outside = root.parent / "outside"
    outside.mkdir()
    (outside / "report.pdf").write_bytes(b"secret")

    def swap_then_allow(path):
        root.rename(root.parent / "moved")
        root.symlink_to(outside)
        return None

    monkeypatch.setattr(uploads, "get_read_block_error", swap_then_allow)

    assert _code(root / "report.pdf", [str(root)]) == "upload_path_invalid"


def test_hosts_without_descriptor_relative_opens_refuse_uploads(root, monkeypatch):
    monkeypatch.setattr(uploads.os, "supports_dir_fd", set())

    assert _code(root / "report.pdf", [str(root)]) == "upload_unsupported"
