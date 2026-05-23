"""Tests for orphan_band.py apply subcommand.

The apply subcommand runs gated orphan anomaly mutations:
1. Gate check (manifest + attestation must be present and valid)
2. First-week mutation cap (>10 anomalies blocked within 7 days of first pass)
3. Per-anomaly _apply_one dispatch
4. Post-pass count against acknowledged_residual
"""

from __future__ import annotations

import argparse
import datetime
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
ORPHAN_BAND_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "orphan_band.py"
)


def _load_orphan_band():
    spec = importlib.util.spec_from_file_location("orphan_band", ORPHAN_BAND_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["orphan_band"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def orphan_band():
    """Load the orphan_band module, failing all tests if absent."""
    if not ORPHAN_BAND_PATH.exists():
        pytest.fail(
            f"orphan_band.py not found at {ORPHAN_BAND_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_orphan_band()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_apply_args(pass_id: str, repo_root: str) -> argparse.Namespace:
    """Build an argparse.Namespace matching the 'apply' subcommand."""
    args = argparse.Namespace()
    args.command = "apply"
    args.pass_id = pass_id
    args.repo_root = repo_root
    return args


def _make_mock_attestation(verify_result: bool) -> types.ModuleType:
    """Return a stub attestation module with controlled verify_attested_commit."""
    mock_attestation = types.ModuleType("_attestation")
    mock_attestation.verify_attested_commit = MagicMock(return_value=verify_result)
    return mock_attestation


def _make_mock_fsck(post_pass_anomalies: list | None = None) -> types.ModuleType:
    """Return a stub fsck module that returns controlled post-pass anomaly data."""
    if post_pass_anomalies is None:
        post_pass_anomalies = []
    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_orphan_anomalies = MagicMock(
        return_value=list(post_pass_anomalies)
    )
    return mock_fsck


def _write_manifest(
    bootstrap_dir: Path,
    pass_id: str,
    anomalies: list | None = None,
) -> Path:
    """Write a manifest JSON file and return its path."""
    if anomalies is None:
        anomalies = []
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = bootstrap_dir / f"orphans-{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps({"pass_id": pass_id, "anomalies": anomalies}))
    return manifest_path


def _write_attestation(
    bootstrap_dir: Path,
    pass_id: str,
    sha: str = "abc123",
    acknowledged_residual: int = 0,
) -> Path:
    """Write an attested.json file and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"orphans-{pass_id}.attested.json"
    attestation_path.write_text(
        json.dumps({"commit_sha": sha, "acknowledged_residual": acknowledged_residual})
    )
    return attestation_path


def _make_sample_anomalies(n: int) -> list[dict]:
    """Return a list of n minimal anomaly dicts."""
    return [
        {
            "ticket_id": f"tick-{i:04d}",
            "jira_key": f"DSO-{100 + i}",
            "class_label": "orphan",
            "side": "local-only",
            "proposed_remediation": "delete orphan mapping",
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_apply_refuses_when_gate_fails(tmp_path, orphan_band):
    """Apply returns exit code 1 and calls zero _apply_one when gate fails."""
    pass_id = "2026-05-22-01"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # Write manifest + attestation so the only failure path is gate verification
    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(2))
    _write_attestation(bootstrap_dir, pass_id, sha="deadbeef")

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    apply_one_mock = MagicMock(
        return_value={"anomaly_id": "irrelevant", "status": "ok", "message": ""}
    )

    # Gate returns False → apply must abort before calling _apply_one
    with (
        patch.object(
            orphan_band, "_load_attestation", return_value=_make_mock_attestation(False)
        ),
        patch.object(orphan_band, "_apply_one", apply_one_mock),
    ):
        rc = orphan_band.cmd_apply(args, tmp_path)

    assert rc == 1
    apply_one_mock.assert_not_called()


def test_apply_enforces_first_week_mutation_cap(tmp_path, orphan_band):
    """Apply returns exit code 1 when first-pass-date is <7 days ago and anomalies>10."""
    pass_id = "2026-05-22-02"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # 11 anomalies — above the cap of 10
    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(11))
    _write_attestation(bootstrap_dir, pass_id)

    # first-pass-date is 1 day ago (within the 7-day window)
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    (bootstrap_dir / "first-pass-date.txt").write_text(yesterday)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    with patch.object(
        orphan_band, "_load_attestation", return_value=_make_mock_attestation(True)
    ):
        rc = orphan_band.cmd_apply(args, tmp_path)

    assert rc == 1


def test_apply_executes_per_anomaly_mutations(tmp_path, orphan_band):
    """Apply calls _apply_one once per anomaly and writes outcome.json with matching count."""
    pass_id = "2026-05-22-03"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = _make_sample_anomalies(5)
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    apply_one_mock = MagicMock(
        side_effect=lambda anomaly, repo_root: {
            "anomaly_id": anomaly.get("ticket_id", "unknown"),
            "status": "ok",
            "message": "applied",
        }
    )

    mock_fsck = _make_mock_fsck(post_pass_anomalies=[])

    with (
        patch.object(
            orphan_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(orphan_band, "_apply_one", apply_one_mock),
        patch.object(orphan_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = orphan_band.cmd_apply(args, tmp_path)

    assert rc == 0
    assert apply_one_mock.call_count == 5

    outcome_path = bootstrap_dir / f"orphans-{pass_id}.outcome.json"
    assert outcome_path.exists(), "outcome.json was not written"
    outcomes = json.loads(outcome_path.read_text())
    assert len(outcomes) == 5


def test_apply_blocks_when_post_pass_count_exceeds_residual(tmp_path, orphan_band):
    """Apply returns exit code 1 when post-pass enumerate returns more than acknowledged_residual."""
    pass_id = "2026-05-22-04"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(2))
    # acknowledged_residual=0 but post-pass returns 2 anomalies
    _write_attestation(bootstrap_dir, pass_id, acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    apply_one_mock = MagicMock(
        return_value={"anomaly_id": "tick-0000", "status": "ok", "message": "applied"}
    )
    mock_fsck = _make_mock_fsck(post_pass_anomalies=_make_sample_anomalies(2))

    with (
        patch.object(
            orphan_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(orphan_band, "_apply_one", apply_one_mock),
        patch.object(orphan_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = orphan_band.cmd_apply(args, tmp_path)

    assert rc == 1


def test_apply_succeeds_when_post_pass_within_residual(tmp_path, orphan_band):
    """Apply returns exit code 0 when post-pass count equals acknowledged_residual (both 0)."""
    pass_id = "2026-05-22-05"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(3))
    _write_attestation(bootstrap_dir, pass_id, acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    apply_one_mock = MagicMock(
        side_effect=lambda anomaly, repo_root: {
            "anomaly_id": anomaly.get("ticket_id", "unknown"),
            "status": "ok",
            "message": "applied",
        }
    )
    mock_fsck = _make_mock_fsck(post_pass_anomalies=[])  # 0 remaining == residual 0

    with (
        patch.object(
            orphan_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(orphan_band, "_apply_one", apply_one_mock),
        patch.object(orphan_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = orphan_band.cmd_apply(args, tmp_path)

    assert rc == 0
