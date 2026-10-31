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
    if not any(resolved.is_relative_to(Path(root).resolve()) for root in roots):
        raise _denied("local_path is outside the configured upload_roots")
    if get_read_block_error(str(resolved)):
        raise _denied("local_path is blocked by the host's file-safety rules")

    # O_NOFOLLOW: the resolved path has no symlinks left, so one swapped in since
    # the check fails the open instead of being followed.
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    try:
        fd = os.open(resolved, flags)
    except OSError:
        raise _invalid("local_path is not a readable regular file") from None
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise _invalid("local_path is not a regular file")
    return os.fdopen(fd, "rb")
