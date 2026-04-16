"""Atomic file write helper shared by bridge modules."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    """Write JSON data to *path* atomically via os.replace (POSIX-atomic rename)."""
    dir_path = path.parent
    dir_path.mkdir(parents=True, exist_ok=True)
    fd, tmp_path_str = tempfile.mkstemp(dir=str(dir_path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp_path_str, str(path))
    except BaseException:
        try:
            os.unlink(tmp_path_str)
        except OSError:
            pass
        raise
