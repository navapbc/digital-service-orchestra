"""Tests for open_count_skew_band.py gate subcommand.

The gate subcommand blocks applier execution until a valid human-signed
reviewer attestation file is present.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
OPEN_COUNT_SKEW_BAND_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "open_count_skew_band.py"
)


def _load_open_count_skew_band():
    spec = importlib.util.spec_from_file_location(
        "open_count_skew_band", OPEN_COUNT_SKEW_BAND_PATH
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["open_count_skew_band"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def open_count_skew_band():
    """Load the open_count_skew_band module, failing all tests if absent."""
    if not OPEN_COUNT_SKEW_BAND_PATH.exists():
        pytest.fail(
            f"open_count_skew_band.py not found at {OPEN_COUNT_SKEW_BAND_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_open_count_skew_band()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_gate_args(pass_id: str, repo_root: str):
    """Build an argparse.Namespace matching the 'gate' subcommand."""
    args = argparse.Namespace()
    args.command = "gate"
    args.pass_id = pass_id
    args.repo_root = repo_root
    return args


def _make_mock_attestation(verify_result: bool) -> types.ModuleType:
    """Return a stub attestation module with controlled verify_attested_commit."""
    mock_attestation = types.ModuleType("_attestation")
    mock_attestation.verify_attested_commit = MagicMock(return_value=verify_result)
    return mock_attestation


def _write_attestation_file(
    bootstrap_dir: Path, pass_id: str, sha: str = "abc123"
) -> Path:
    """Write a minimal attested.json file and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"open-count-skew-{pass_id}.attested.json"
    attestation_path.write_text(json.dumps({"commit_sha": sha}))
    return attestation_path


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_gate_fails_when_attestation_missing(tmp_path, open_count_skew_band, capsys):
    """Gate returns exit code 1 with 'attestation missing' when no attested.json exists."""
    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    # Do NOT create bridge_state/bootstrap/ or any attested.json
    with patch.object(
        open_count_skew_band,
        "_load_attestation",
        return_value=_make_mock_attestation(True),
    ):
        rc = open_count_skew_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "attestation missing" in captured.err


def test_gate_fails_when_commit_sha_absent(tmp_path, open_count_skew_band, capsys):
    """Gate returns exit code 1 when attested.json has no commit_sha."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True, exist_ok=True)

    # Write attested.json with no commit_sha
    attestation_path = bootstrap_dir / "open-count-skew-no-sha-pass.attested.json"
    attestation_path.write_text(json.dumps({"some_other_key": "value"}))

    args = _make_gate_args(pass_id="no-sha-pass", repo_root=str(tmp_path))

    with patch.object(
        open_count_skew_band,
        "_load_attestation",
        return_value=_make_mock_attestation(True),
    ):
        rc = open_count_skew_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "commit_sha" in captured.err


def test_gate_fails_when_bot_attests(tmp_path, open_count_skew_band, capsys):
    """Gate returns exit code 1 when committer is a bot (verify_attested_commit returns False)."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    _write_attestation_file(bootstrap_dir, "bot-pass", sha="deadbeef")

    args = _make_gate_args(pass_id="bot-pass", repo_root=str(tmp_path))

    # verify_attested_commit returns False; git verify-commit succeeds → bot is the reason
    mock_attestation = _make_mock_attestation(False)
    mock_proc = MagicMock()
    mock_proc.returncode = 0  # git verify-commit passes → signature OK → bot committer

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=mock_attestation,
        ),
        patch("open_count_skew_band.subprocess.run", return_value=mock_proc),
    ):
        rc = open_count_skew_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "bot" in captured.err


def test_gate_passes_valid_human_attestation(tmp_path, open_count_skew_band, capsys):
    """Gate returns exit code 0 when attestation is present and signed by a human."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    _write_attestation_file(bootstrap_dir, "human-pass", sha="abc123")

    args = _make_gate_args(pass_id="human-pass", repo_root=str(tmp_path))

    # verify_attested_commit returns True → all checks pass
    mock_attestation = _make_mock_attestation(True)

    with patch.object(
        open_count_skew_band,
        "_load_attestation",
        return_value=mock_attestation,
    ):
        rc = open_count_skew_band.cmd_gate(args, tmp_path)

    assert rc == 0
    captured = capsys.readouterr()
    assert "GATE OK" in captured.out
