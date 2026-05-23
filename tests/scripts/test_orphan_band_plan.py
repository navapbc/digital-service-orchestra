"""Tests for orphan_band.py plan subcommand.

Story DD: "An orphan-band dry-run manifest enumerates every orphan anomaly
with class label, side (local-only or jira-only), and proposed remediation,
written to bridge_state/bootstrap/orphans-<pass>.manifest.json"
"""

from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
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
# Shared test data
# ---------------------------------------------------------------------------

_SAMPLE_ANOMALIES = [
    {
        "ticket_id": "tick-0001",
        "jira_key": "DSO-101",
        "class_label": "orphan",
        "side": "local-only",
        "proposed_remediation": "delete orphan mapping",
    },
    {
        "ticket_id": "tick-0002",
        "jira_key": "DSO-102",
        "class_label": "orphan",
        "side": "local-only",
        "proposed_remediation": "delete orphan mapping",
    },
    {
        "ticket_id": None,
        "jira_key": "DSO-103",
        "class_label": "orphan",
        "side": "jira-only",
        "proposed_remediation": "delete orphan mapping",
    },
]


def _make_mock_fsck(anomalies=None):
    """Return a stub fsck module that returns controlled anomaly data."""
    if anomalies is None:
        anomalies = _SAMPLE_ANOMALIES

    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_orphan_anomalies = lambda _tickets_dir: list(anomalies)
    return mock_fsck


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_plan_writes_manifest_with_three_anomalies(tmp_path, orphan_band):
    """Manifest file is written with 3 anomaly records."""
    # Setup: tmp repo_root with .tickets-tracker directory
    (tmp_path / ".tickets-tracker").mkdir()

    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with patch.object(orphan_band, "_load_fsck", return_value=_make_mock_fsck()):
        orphan_band.cmd_plan(args, tmp_path)

    manifest_path = (
        tmp_path / "bridge_state" / "bootstrap" / "orphans-2026-05-22-01.manifest.json"
    )
    assert manifest_path.exists(), f"manifest not found at {manifest_path}"

    manifest = json.loads(manifest_path.read_text())
    assert manifest["pass_id"] == "2026-05-22-01"
    assert "anomalies" in manifest
    assert len(manifest["anomalies"]) == 3


def test_plan_exit_code_zero(tmp_path, orphan_band):
    """cmd_plan returns exit code 0 on success."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with patch.object(orphan_band, "_load_fsck", return_value=_make_mock_fsck()):
        rc = orphan_band.cmd_plan(args, tmp_path)

    assert rc == 0


def test_manifest_contains_required_fields(tmp_path, orphan_band):
    """Each anomaly record in the manifest contains class_label, side, and proposed_remediation."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with patch.object(orphan_band, "_load_fsck", return_value=_make_mock_fsck()):
        orphan_band.cmd_plan(args, tmp_path)

    manifest_path = (
        tmp_path / "bridge_state" / "bootstrap" / "orphans-2026-05-22-01.manifest.json"
    )
    manifest = json.loads(manifest_path.read_text())

    for i, anomaly in enumerate(manifest["anomalies"]):
        assert "class_label" in anomaly, f"anomaly[{i}] missing class_label"
        assert "side" in anomaly, f"anomaly[{i}] missing side"
        assert "proposed_remediation" in anomaly, (
            f"anomaly[{i}] missing proposed_remediation"
        )

    # Verify the mix of sides from our test data
    sides = {a["side"] for a in manifest["anomalies"]}
    assert "local-only" in sides
    assert "jira-only" in sides


def test_plan_creates_output_dir_if_absent(tmp_path, orphan_band):
    """cmd_plan creates bridge_state/bootstrap/ if it does not exist."""
    (tmp_path / ".tickets-tracker").mkdir()
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    assert not bootstrap_dir.exists(), "test precondition: bootstrap dir must not exist"

    args = _make_plan_args(pass_id="2026-05-22-02", repo_root=str(tmp_path))

    with patch.object(orphan_band, "_load_fsck", return_value=_make_mock_fsck()):
        rc = orphan_band.cmd_plan(args, tmp_path)

    assert rc == 0
    assert bootstrap_dir.is_dir(), "bootstrap dir was not created"
    manifest_path = bootstrap_dir / "orphans-2026-05-22-02.manifest.json"
    assert manifest_path.exists(), "manifest file was not created"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_plan_args(pass_id: str, repo_root: str):
    """Build an argparse.Namespace matching the 'plan' subcommand."""
    import argparse

    args = argparse.Namespace()
    args.command = "plan"
    args.pass_id = pass_id
    args.repo_root = repo_root
    return args
