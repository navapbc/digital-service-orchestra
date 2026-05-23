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
    add_calls: list = []
    commit_calls: list = []

    def fake_subprocess_run(cmd, **kwargs):
        # Discriminate the two rev-parse forms: `rev-parse tickets` resolves
        # the head SHA, `rev-parse --abbrev-ref HEAD` returns the branch name.
        # Pre-fix this collided and the commit path was never exercised.
        if cmd[0] == "git" and cmd[1] == "rev-parse" and cmd[2:] == ["tickets"]:
            return _make_proc(0, stdout="abc123\n")
        if (
            cmd[0] == "git"
            and cmd[1] == "rev-parse"
            and cmd[2:] == ["--abbrev-ref", "HEAD"]
        ):
            return _make_proc(0, stdout="tickets\n")  # force the commit path
        if cmd[0] == "git" and cmd[1] == "show":
            return _make_proc(0, stdout=json.dumps(outbound_data))
        if cmd[0] == "git" and cmd[1] == "add":
            add_calls.append(cmd)
            return _make_proc(0)
        if cmd[0] == "git" and cmd[1] == "commit":
            commit_calls.append(cmd)
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
    # Branch was 'tickets' so the commit path must have been taken — pin this
    # so a future regression that breaks add/commit invocation is caught.
    assert len(add_calls) == 1, (
        f"expected exactly one git add call, got {len(add_calls)}"
    )
    assert len(commit_calls) == 1, (
        f"expected exactly one git commit call, got {len(commit_calls)}"
    )
    assert result.details.get("committed") is True
    assert result.details.get("branch") == "tickets"


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
    """Verify that os.replace is called with a source path that is a tempfile in the same dir.

    cursor_snapshot uses os.replace (not os.rename) for cross-platform atomic
    overwrite semantics — on Windows, os.rename fails if the destination exists,
    while os.replace overwrites atomically on all platforms.
    """
    cs = _load_cursor_snapshot()

    bridge_state = tmp_path / "bridge_state"
    bridge_state.mkdir()

    rename_calls = []
    original_replace = __import__("os").replace

    def capture_replace(src, dst):
        rename_calls.append((Path(src), Path(dst)))
        original_replace(src, dst)

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse" and cmd[2:] == ["tickets"]:
            return _make_proc(0, stdout="deadbeef\n")
        if (
            cmd[0] == "git"
            and cmd[1] == "rev-parse"
            and cmd[2:] == ["--abbrev-ref", "HEAD"]
        ):
            return _make_proc(0, stdout="tickets\n")
        if cmd[0] == "git" and cmd[1] == "show":
            return _make_proc(1, stderr="not found")  # no outbound checkpoint
        if cmd[0] == "git" and cmd[1] == "add":
            return _make_proc(0)
        if cmd[0] == "git" and cmd[1] == "commit":
            return _make_proc(0)
        return _make_proc(1, stderr="unexpected")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        with patch("os.replace", side_effect=capture_replace):
            result = cs.run(repo_root=tmp_path)

    assert result.ok is True, f"Expected ok=True, got message: {result.message}"
    assert len(rename_calls) == 1, "Expected exactly one os.replace call"
    src, dst = rename_calls[0]
    # Source must be in the same directory as destination (bridge_state)
    assert src.parent == dst.parent, (
        f"Tempfile {src} not in same dir as destination {dst}"
    )
    # Source filename should start with the temp prefix
    assert src.name.startswith(".cursor-snapshot-tmp.")
    # Destination should be the actual snapshot path
    assert dst.name == "cursor-snapshot.json"


def test_commit_skipped_when_not_on_tickets_branch(tmp_path):
    """When the current branch is not 'tickets', the snapshot is still written
    to disk but git add/commit are NOT invoked, and details['committed'] is
    False. This pins the safety invariant: cursor_snapshot must not commit
    to whatever branch happens to be checked out — only to 'tickets'."""
    cs = _load_cursor_snapshot()

    bridge_state = tmp_path / "bridge_state"
    bridge_state.mkdir()

    add_calls: list = []
    commit_calls: list = []

    def fake_subprocess_run(cmd, **kwargs):
        if cmd[0] == "git" and cmd[1] == "rev-parse" and cmd[2:] == ["tickets"]:
            return _make_proc(0, stdout="abc123\n")
        if (
            cmd[0] == "git"
            and cmd[1] == "rev-parse"
            and cmd[2:] == ["--abbrev-ref", "HEAD"]
        ):
            return _make_proc(0, stdout="feature/foo\n")  # NOT tickets
        if cmd[0] == "git" and cmd[1] == "show":
            return _make_proc(1, stderr="no outbound checkpoint")
        if cmd[0] == "git" and cmd[1] == "add":
            add_calls.append(cmd)
            return _make_proc(0)
        if cmd[0] == "git" and cmd[1] == "commit":
            commit_calls.append(cmd)
            return _make_proc(0)
        return _make_proc(1, stderr="unexpected call")

    with patch("subprocess.run", side_effect=fake_subprocess_run):
        result = cs.run(repo_root=tmp_path)

    # ok=True (no error happened), but committed=False so callers requiring
    # a durable tickets-branch commit can detect the skip.
    assert result.ok is True
    assert result.details.get("committed") is False, (
        "When not on tickets branch, details['committed'] MUST be False — "
        "callers depend on this flag to distinguish 'commit happened' from "
        "'commit was skipped'."
    )
    assert result.details.get("branch") == "feature/foo"
    assert "commit step skipped" in result.message
    # The snapshot file IS still written even though commit was skipped —
    # _write_snapshot_atomically runs before the commit step.
    assert (bridge_state / "cursor-snapshot.json").exists()
    # No git add or git commit calls should have been made.
    assert add_calls == [], (
        f"git add must not be called when not on tickets branch: {add_calls}"
    )
    assert commit_calls == [], (
        f"git commit must not be called when not on tickets branch: {commit_calls}"
    )
