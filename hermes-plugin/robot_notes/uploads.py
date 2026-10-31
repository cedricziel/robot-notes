"""Confines ``robotnotes_upload_file`` reads to the configured ``upload_roots``.

The model names a local path; nothing here ever returns file content to it. A
path is accepted only when, with ``~`` expanded and every symlink and ``..``
resolved, it is a regular file at or under one resolved root and the host's own
read denylist (``agent.file_safety``) doesn't block it.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path
from typing import BinaryIO, Sequence

from ._hermes_compat import get_read_block_error
from .client import ClientError


def _invalid(message: str) -> ClientError:
    return ClientError(message, code="upload_path_invalid")


def _denied(message: str) -> ClientError:
    return ClientError(message, code="upload_path_denied")


def open_upload_source(local_path: str, roots: Sequence[str]) -> BinaryIO:
    expanded = Path(local_path).expanduser()
    if not expanded.is_absolute():
        raise _invalid("local_path must be an absolute path")
    try:
        resolved = expanded.resolve(strict=True)
    except (OSError, RuntimeError):
        raise _invalid("local_path does not exist") from None
    root = next((r for r in map(Path.resolve, map(Path, roots)) if resolved.is_relative_to(r)), None)
    if root is None:
        raise _denied("local_path is outside the configured upload_roots")
    if get_read_block_error(str(resolved)):
        raise _denied("local_path is blocked by the host's file-safety rules")
    parts = resolved.relative_to(root).parts
    if not parts:
        raise _invalid("local_path is not a regular file")
    try:
        fd = _open_beneath(root, parts)
    except OSError:
        raise _invalid("local_path is not a readable regular file") from None
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise _invalid("local_path is not a regular file")
    return os.fdopen(fd, "rb")


def _open_beneath(root: Path, parts: tuple[str, ...]) -> int:
    """Opens ``root/parts...`` one component at a time from a descriptor on ``root``,
    refusing symlinks at every step, so a directory swapped for a link after the
    containment check cannot redirect the open outside the root."""
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if os.open not in os.supports_dir_fd:
        return os.open(root.joinpath(*parts), os.O_RDONLY | nofollow | getattr(os, "O_BINARY", 0))
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=fd)
            os.close(fd)
            fd = child
        return os.open(parts[-1], os.O_RDONLY | nofollow, dir_fd=fd)
    finally:
        os.close(fd)
