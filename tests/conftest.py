"""Repo-wide pytest configuration.

Provides an autouse fixture that prevents tests from creating new top-level
entries in REPO_ROOT. Tests that write to disk must use ``tmp_path`` or
another sandboxed location. If a test leaks, the leak is cleaned up and the
test fails with a message naming the new entries.

This guard catches the most common leak shape — relative-path writes from
mis-routed tracker_dir/cwd handling (the failure mode that put
``depends_on/tkt-src3`` at the repo root). It does NOT catch writes that
target an existing top-level dir (e.g. ``plugins/dso/scripts/x.json``); for
that level of guarantee, run ``git status --porcelain`` in CI.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Iterator

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(autouse=True)
def _no_repo_root_leaks() -> Iterator[None]:
    before = set(os.listdir(_REPO_ROOT))
    try:
        yield
    finally:
        after = set(os.listdir(_REPO_ROOT))
        leaked = after - before
        if not leaked:
            return
        for name in leaked:
            target = _REPO_ROOT / name
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            else:
                try:
                    target.unlink()
                except OSError:
                    pass
        pytest.fail(
            "Test leaked new entries into REPO_ROOT (use tmp_path or a "
            f"sandboxed temp dir): {sorted(leaked)}"
        )
