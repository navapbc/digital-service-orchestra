"""Tests for cursor_snapshot.py — cursor snapshot step for the dso reconciler.

Verifies: success path, idempotency, missing-branch failure, and atomic write via tempfile.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch


# ---------------------------------------------------------------------------
# Module loading via importlib (project convention — no package install)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
CURSOR_SNAPSHOT_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "cursor_snapshot.py"
)


def _load_cursor_snapshot():
    """Load cursor_snapshot module fresh for each test."""
    spec = importlib.util.spec_from_file_location(
        "cursor_snapshot", CURSOR_SNAPSHOT_PATH
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cursor_snapshot"] = mod
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop("cursor_snapshot", None)
    return mod


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_proc(returncode: int, stdout: str = "", stderr: str = "") -> CompletedProcess:
    """Build a fake CompletedProcess."""
    return CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_returns_ok_on_success(tmp_path):
    """Happy path: rev-parse succeeds, outbound checkpoint present, no inbound cursor."""
    cs = _load_cursor_snapshot()

    # Build a fake repo_root with bridge_state dir (no existing snapshot)
    bridge_state = tmp_path / "bridge_state"
    bridge_state.mkdir()

    outbound_data = {"sha": "old"}

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse":
            return _make_proc(0, stdout="abc123\n")
        if cmd[0] == "git" and cmd[1] == "show":
            return _make_proc(0, stdout=json.dumps(outbound_data))
        if cmd[0] == "git" and cmd[1] == "add":
            return _make_proc(0)
        if cmd[0] == "git" and cmd[1] == "commit":
            return _make_proc(0)
        return _make_proc(1, stderr="unexpected call")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        result = cs.run(repo_root=tmp_path)

    assert result.ok is True
    assert result.name == "cursor_snapshot"
    # snapshot file should have been written
    snapshot_file = bridge_state / "cursor-snapshot.json"
    assert snapshot_file.exists()
    data = json.loads(snapshot_file.read_text())
    assert data["head_sha"] == "abc123"
    assert data["outbound_checkpoint"] == outbound_data


def test_idempotent_when_same_sha(tmp_path):
    """When snapshot already contains the current head_sha, skip and return skipped=True."""
    cs = _load_cursor_snapshot()

    bridge_state = tmp_path / "bridge_state"
    bridge_state.mkdir()
    snapshot_file = bridge_state / "cursor-snapshot.json"
    snapshot_file.write_text(json.dumps({"head_sha": "abc123"}))

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse":
            return _make_proc(0, stdout="abc123\n")
        # Should not reach git show/add/commit in idempotent case
        return _make_proc(1, stderr="should not be called")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        result = cs.run(repo_root=tmp_path)

    assert result.ok is True
    assert result.details.get("skipped") is True
    assert result.details.get("head_sha") == "abc123"


def test_returns_fail_when_tickets_branch_absent(tmp_path):
    """When git rev-parse tickets returns non-zero, result is ok=False with message about tickets branch."""
    cs = _load_cursor_snapshot()

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse":
            return _make_proc(
                128, stderr="unknown revision or path not in the working tree"
            )
        return _make_proc(1, stderr="should not reach")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        result = cs.run(repo_root=tmp_path)

    assert result.ok is False
    assert "tickets branch" in result.message


def test_atomic_write_uses_tempfile(tmp_path):
    """Verify that os.rename is called with a source path that is a tempfile in the same dir."""
    cs = _load_cursor_snapshot()

    bridge_state = tmp_path / "bridge_state"
    bridge_state.mkdir()

    rename_calls = []
    original_rename = __import__("os").rename

    def capture_rename(src, dst):
        rename_calls.append((Path(src), Path(dst)))
        original_rename(src, dst)

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse":
            return _make_proc(0, stdout="deadbeef\n")
        if cmd[0] == "git" and cmd[1] == "show":
            return _make_proc(1, stderr="not found")  # no outbound checkpoint
        if cmd[0] == "git" and cmd[1] == "add":
            return _make_proc(0)
        if cmd[0] == "git" and cmd[1] == "commit":
            return _make_proc(0)
        return _make_proc(1, stderr="unexpected")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        with patch("os.rename", side_effect=capture_rename):
            result = cs.run(repo_root=tmp_path)

    assert result.ok is True, f"Expected ok=True, got message: {result.message}"
    assert len(rename_calls) == 1, "Expected exactly one os.rename call"
    src, dst = rename_calls[0]
    # Source must be in the same directory as destination (bridge_state)
    assert src.parent == dst.parent, (
        f"Tempfile {src} not in same dir as destination {dst}"
    )
    # Source filename should start with the temp prefix
    assert src.name.startswith(".cursor-snapshot-tmp.")
    # Destination should be the actual snapshot path
    assert dst.name == "cursor-snapshot.json"
