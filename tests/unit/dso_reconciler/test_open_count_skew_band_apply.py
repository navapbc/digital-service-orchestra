"""Tests for open_count_skew_band.py apply subcommand.

The apply subcommand runs gated open-count type skew mutations:
1. Inline gate check (attestation must be present and valid)
2. Per-anomaly create_issue (delta>0) or transition_issue (delta<0) calls
3. Post-pass tolerance check against acknowledged_residual (default ±5)
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
    mock_fsck.enumerate_open_count_skew_anomalies = MagicMock(
        return_value=list(post_pass_anomalies)
    )
    return mock_fsck


def _make_mock_acli(call_log: list | None = None) -> types.ModuleType:
    """Return a stub acli module whose AcliClient records method calls."""
    log = call_log if call_log is not None else []

    class _MockClient:
        def create_issue(self, type, summary):  # noqa: A002
            log.append(("create_issue", type))

        def search_issues(self, type):  # noqa: A002
            # Return a list of fake issue dicts sufficient for any test
            return [{"key": f"DSO-{i}"} for i in range(20)]

        def transition_issue(self, issue_key, status):
            log.append(("transition_issue", issue_key))

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _MockClient
    return mock_acli


def _write_manifest(
    bootstrap_dir: Path,
    pass_id: str,
    anomalies: list | None = None,
) -> Path:
    """Write an open-count-skew manifest JSON and return its path."""
    if anomalies is None:
        anomalies = []
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = bootstrap_dir / f"open-count-skew-{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps({"pass_id": pass_id, "anomalies": anomalies}))
    return manifest_path


def _write_attestation(
    bootstrap_dir: Path,
    pass_id: str,
    sha: str = "abc123",
    acknowledged_residual: int = 5,
) -> Path:
    """Write an open-count-skew attested.json and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"open-count-skew-{pass_id}.attested.json"
    attestation_path.write_text(
        json.dumps(
            {"commit_sha": sha, "acknowledged_residual": acknowledged_residual}
        )
    )
    return attestation_path


def _make_anomaly(ttype: str, delta: int) -> dict:
    """Return a minimal open-count skew anomaly dict."""
    return {"type": ttype, "delta": delta}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_apply_refuses_when_gate_fails(tmp_path, open_count_skew_band):
    """Apply returns exit code 1 and makes zero AcliClient calls when gate fails."""
    pass_id = "2026-05-22-skew-01"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # Write manifest but NO attestation file — gate must fail
    _write_manifest(bootstrap_dir, pass_id, anomalies=[_make_anomaly("story", 2)])

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=_make_mock_attestation(True),
        ),
        patch.object(open_count_skew_band, "_load_acli", return_value=mock_acli),
        patch.object(
            open_count_skew_band,
            "_load_fsck",
            return_value=_make_mock_fsck(),
        ),
    ):
        rc = open_count_skew_band.cmd_apply(args, tmp_path)

    assert rc == 1
    assert call_log == [], "Expected zero AcliClient calls when gate fails"


def test_apply_creates_issues_for_positive_delta(tmp_path, open_count_skew_band):
    """Apply calls create_issue delta times when delta > 0 (local has more than Jira)."""
    pass_id = "2026-05-22-skew-02"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [_make_anomaly("story", 2)]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id, sha="deadbeef")

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=_make_mock_attestation(True),
        ),
        patch.object(open_count_skew_band, "_load_acli", return_value=mock_acli),
        patch.object(
            open_count_skew_band,
            "_load_fsck",
            return_value=_make_mock_fsck(post_pass_anomalies=[]),
        ),
    ):
        rc = open_count_skew_band.cmd_apply(args, tmp_path)

    assert rc == 0
    create_calls = [c for c in call_log if c[0] == "create_issue"]
    assert len(create_calls) == 2, f"Expected 2 create_issue calls, got {len(create_calls)}"


def test_apply_closes_issues_for_negative_delta(tmp_path, open_count_skew_band):
    """Apply calls transition_issue abs(delta) times when delta < 0 (Jira has more)."""
    pass_id = "2026-05-22-skew-03"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [_make_anomaly("task", -2)]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id, sha="deadbeef")

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=_make_mock_attestation(True),
        ),
        patch.object(open_count_skew_band, "_load_acli", return_value=mock_acli),
        patch.object(
            open_count_skew_band,
            "_load_fsck",
            return_value=_make_mock_fsck(post_pass_anomalies=[]),
        ),
    ):
        rc = open_count_skew_band.cmd_apply(args, tmp_path)

    assert rc == 0
    transition_calls = [c for c in call_log if c[0] == "transition_issue"]
    assert len(transition_calls) == 2, (
        f"Expected 2 transition_issue calls, got {len(transition_calls)}"
    )


def test_apply_blocks_when_post_pass_exceeds_tolerance(tmp_path, open_count_skew_band):
    """Apply returns exit code 1 when post-pass residual delta exceeds acknowledged_residual."""
    pass_id = "2026-05-22-skew-04"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [_make_anomaly("epic", 1)]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    # acknowledged_residual=5 but post-pass has delta=10 (> 5)
    _write_attestation(bootstrap_dir, pass_id, sha="deadbeef", acknowledged_residual=5)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)
    # Post-pass returns anomaly with delta=10 — exceeds tolerance of 5
    mock_fsck = _make_mock_fsck(
        post_pass_anomalies=[_make_anomaly("epic", 10)]
    )

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=_make_mock_attestation(True),
        ),
        patch.object(open_count_skew_band, "_load_acli", return_value=mock_acli),
        patch.object(open_count_skew_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = open_count_skew_band.cmd_apply(args, tmp_path)

    assert rc == 1


def test_apply_succeeds_when_post_pass_within_tolerance(tmp_path, open_count_skew_band):
    """Apply returns exit code 0 when all post-pass deltas are within ±acknowledged_residual."""
    pass_id = "2026-05-22-skew-05"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [_make_anomaly("story", 3)]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    # acknowledged_residual=5; post-pass residual of 4 is within tolerance
    _write_attestation(bootstrap_dir, pass_id, sha="deadbeef", acknowledged_residual=5)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)
    # Post-pass returns anomaly with delta=4 — within tolerance of 5
    mock_fsck = _make_mock_fsck(
        post_pass_anomalies=[_make_anomaly("story", 4)]
    )

    with (
        patch.object(
            open_count_skew_band,
            "_load_attestation",
            return_value=_make_mock_attestation(True),
        ),
        patch.object(open_count_skew_band, "_load_acli", return_value=mock_acli),
        patch.object(open_count_skew_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = open_count_skew_band.cmd_apply(args, tmp_path)

    assert rc == 0

    # Verify applied.json was written
    applied_path = bootstrap_dir / f"open-count-skew-{pass_id}.applied.json"
    assert applied_path.exists(), "applied.json was not written"
    result = json.loads(applied_path.read_text())
    assert "outcomes" in result
