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
    if os.open not in os.supports_dir_fd:
        raise ClientError("This host cannot open files without following symlinks; uploads are unavailable",
                          code="upload_unsupported")
    expanded = Path(local_path).expanduser()
    if not expanded.is_absolute():
        raise _invalid("local_path must be an absolute path")
    try:
        resolved = expanded.resolve(strict=True)
    except (OSError, RuntimeError):
        raise _invalid("local_path does not exist") from None
    if not any(resolved.is_relative_to(Path(root).resolve()) for root in roots):
        raise _denied("local_path is outside the configured upload_roots")
    if get_read_block_error(str(resolved)):
        raise _denied("local_path is blocked by the host's file-safety rules")
    try:
        fd = _open_without_links(resolved)
    except (OSError, ValueError):
        raise _invalid("local_path is not a readable regular file") from None
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise _invalid("local_path is not a regular file")
    return os.fdopen(fd, "rb")


def _open_without_links(resolved: Path) -> int:
    """Opens ``resolved`` one component at a time from ``/``, refusing a symlink at
    every step. ``resolved`` has none, so a directory (the root included) swapped
    for a link after the containment check fails the open instead of redirecting it."""
    *folders, name = resolved.parts[1:]
    fd = os.open(resolved.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for folder in folders:
            child = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    finally:
        os.close(fd)
