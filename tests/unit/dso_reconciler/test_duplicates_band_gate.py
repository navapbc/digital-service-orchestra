"""Tests for duplicates_band.py gate subcommand.

The gate subcommand blocks applier execution until a valid human-signed
reviewer attestation file is present.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
DUPLICATES_BAND_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "duplicates_band.py"
)


def _load_duplicates_band():
    spec = importlib.util.spec_from_file_location(
        "duplicates_band", DUPLICATES_BAND_PATH
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["duplicates_band"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def duplicates_band():
    """Load the duplicates_band module, failing all tests if absent."""
    if not DUPLICATES_BAND_PATH.exists():
        pytest.fail(
            f"duplicates_band.py not found at {DUPLICATES_BAND_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_duplicates_band()


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


def _write_attestation_file(
    bootstrap_dir: Path, pass_id: str, sha: str = "abc123"
) -> Path:
    """Write a minimal attested.json file and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"duplicates-{pass_id}.attested.json"
    attestation_path.write_text(json.dumps({"commit_sha": sha}))
    return attestation_path


def _make_subprocess_mock(
    verify_returncode: int = 0, committer_email: str = "human@example.com"
):
    """Return a side_effect function for subprocess.run that handles both git calls."""

    def _side_effect(cmd, **kwargs):
        mock = MagicMock()
        if cmd[1] == "verify-commit":
            mock.returncode = verify_returncode
        elif cmd[1] == "log":
            mock.returncode = 0
            mock.stdout = committer_email + "\n"
        else:
            mock.returncode = 0
            mock.stdout = ""
        return mock

    return _side_effect


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_gate_fails_when_attestation_missing(tmp_path, duplicates_band, capsys):
    """Gate returns exit code 1 with 'attestation missing' when no attested.json exists."""
    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    # Do NOT create bridge_state/bootstrap/ or any attested.json
    rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "GATE FAIL: attestation missing" in captured.err


def test_gate_fails_when_commit_sha_absent(tmp_path, duplicates_band, capsys):
    """Gate returns exit code 1 when attested.json exists but has no commit_sha."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / "duplicates-test-pass.attested.json"
    # Write attestation without commit_sha
    attestation_path.write_text(json.dumps({"some_other_field": "value"}))

    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "commit_sha" in captured.err


def test_gate_fails_when_signature_invalid(tmp_path, duplicates_band, capsys):
    """Gate returns exit code 1 with 'attestation signature invalid' when git verify-commit fails."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    _write_attestation_file(bootstrap_dir, "test-pass", sha="deadbeef")

    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    with patch(
        "duplicates_band.subprocess.run",
        side_effect=_make_subprocess_mock(verify_returncode=1),
    ):
        rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "attestation signature invalid" in captured.err


def test_gate_fails_when_bot_attests(tmp_path, duplicates_band, capsys):
    """Gate returns exit code 1 with 'attestation committer is a bot' when committer is a bot."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    _write_attestation_file(bootstrap_dir, "test-pass", sha="deadbeef")

    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    # Signature valid but committer is a bot
    with patch(
        "duplicates_band.subprocess.run",
        side_effect=_make_subprocess_mock(
            verify_returncode=0,
            committer_email="github-actions[bot]@users.noreply.github.com",
        ),
    ):
        rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "attestation committer is a bot" in captured.err


def test_gate_passes_valid_human_attestation(tmp_path, duplicates_band, capsys):
    """Gate returns exit code 0 when attestation is present and signed by a human."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    _write_attestation_file(bootstrap_dir, "test-pass", sha="abc123")

    args = _make_gate_args(pass_id="test-pass", repo_root=str(tmp_path))

    with patch(
        "duplicates_band.subprocess.run",
        side_effect=_make_subprocess_mock(
            verify_returncode=0,
            committer_email="human@example.com",
        ),
    ):
        rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 0
    captured = capsys.readouterr()
    assert "GATE OK" in captured.out


def test_gate_rejects_swapped_manifest(tmp_path, duplicates_band, capsys):
    """F8 regression: gate rejects an apply when manifest was swapped after attestation."""
    import hashlib

    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True)

    manifest_path = bootstrap_dir / "duplicates-swap-pass.manifest.json"
    original = b'{"pass_id": "swap-pass", "anomalies": []}'
    manifest_path.write_bytes(original)
    attested_hash = hashlib.sha256(original).hexdigest()

    attestation_path = bootstrap_dir / "duplicates-swap-pass.attested.json"
    attestation_path.write_text(
        json.dumps({"commit_sha": "abc123", "manifest_hash": attested_hash})
    )

    # Swap manifest after attestation — gate must detect
    swapped = b'{"pass_id": "swap-pass", "anomalies": [{"injected": true}]}'
    manifest_path.write_bytes(swapped)

    args = _make_gate_args(pass_id="swap-pass", repo_root=str(tmp_path))

    with patch(
        "duplicates_band.subprocess.run",
        side_effect=_make_subprocess_mock(verify_returncode=0),
    ):
        rc = duplicates_band.cmd_gate(args, tmp_path)

    assert rc == 1
    captured = capsys.readouterr()
    assert "manifest hash mismatch" in captured.err
