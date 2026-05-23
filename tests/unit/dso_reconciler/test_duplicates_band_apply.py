"""Tests for duplicates_band.py apply subcommand.

The apply subcommand runs gated duplicate anomaly mutations:
1. Inline gate check (attestation must be present and valid)
2. Per-anomaly deletion of duplicate LOCAL mappings via the dso ticket CLI
   (Jira is not touched — a duplicate set is N local mappings to ONE Jira
   key; Jira owns a single issue and has nothing to remediate)
3. Post-pass count against acknowledged_residual
4. apply.log.json written with per-set outcomes
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import types
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


def _make_apply_args(pass_id: str, repo_root: str) -> argparse.Namespace:
    """Build an argparse.Namespace matching the 'apply' subcommand."""
    args = argparse.Namespace()
    args.command = "apply"
    args.pass_id = pass_id
    args.repo_root = repo_root
    return args


def _make_mock_acli(call_log: list | None = None) -> types.ModuleType:
    """Return a stub acli module — kept for backward-compat with patch sites.

    After F2 the duplicates band no longer calls AcliClient at all (the
    remediation is purely local: delete the duplicate local mappings via
    the dso ticket CLI). This stub is preserved so existing tests that
    pass ``_load_acli`` patches don't break, and so any future Jira-side
    extension can plug in without re-introducing the patch wiring.
    """
    log = call_log if call_log is not None else []

    class _MockClient:
        def __init__(self, *args, **kwargs):
            pass

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _MockClient
    return mock_acli


def _make_mock_fsck(post_pass_anomalies: list | None = None) -> types.ModuleType:
    """Return a stub fsck module that returns controlled post-pass anomaly data."""
    if post_pass_anomalies is None:
        post_pass_anomalies = []
    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_duplicate_anomalies = MagicMock(
        return_value=list(post_pass_anomalies)
    )
    return mock_fsck


def _make_subprocess_mock(
    verify_returncode: int = 0,
    committer_email: str = "human@example.com",
    delete_returncode: int = 0,
    delete_log: list | None = None,
):
    """Build a subprocess.run side_effect covering both gate and apply paths.

    Handles three call shapes:
      - ``git verify-commit <sha>`` — gate signature check
      - ``git log -1 --format=%ae <sha>`` — gate committer email
      - ``<dso-cli> ticket delete <id> --user-approved`` — apply path
        (records the deleted ticket_id to ``delete_log`` when provided)
    """

    def _side_effect(cmd, **kwargs):
        mock = MagicMock(spec=subprocess.CompletedProcess)
        mock.stdout = ""
        mock.stderr = ""
        if cmd and cmd[0] == "git" and cmd[1] == "verify-commit":
            mock.returncode = verify_returncode
        elif cmd and cmd[0] == "git" and cmd[1] == "log":
            mock.returncode = 0
            mock.stdout = committer_email + "\n"
        elif "ticket" in cmd and "delete" in cmd:
            mock.returncode = delete_returncode
            if delete_log is not None:
                # cmd shape: [cli, "ticket", "delete", <id>, "--user-approved"]
                delete_log.append(cmd[cmd.index("delete") + 1])
        else:
            mock.returncode = 0
        return mock

    return _side_effect


def _write_manifest(
    bootstrap_dir: Path,
    pass_id: str,
    anomalies: list | None = None,
) -> Path:
    """Write a duplicates manifest JSON and return its path."""
    if anomalies is None:
        anomalies = []
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = bootstrap_dir / f"duplicates-{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps({"pass_id": pass_id, "anomalies": anomalies}))
    return manifest_path


def _write_attestation(
    bootstrap_dir: Path,
    pass_id: str,
    sha: str = "abc123",
    acknowledged_residual: int = 0,
) -> Path:
    """Write a duplicates attested.json and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"duplicates-{pass_id}.attested.json"
    attestation_path.write_text(
        json.dumps({"commit_sha": sha, "acknowledged_residual": acknowledged_residual})
    )
    return attestation_path


def _make_sample_anomalies(n: int = 1) -> list[dict]:
    """Return a list of n minimal duplicate anomaly dicts.

    Each anomaly models N local ticket UUIDs all mapped to ONE Jira key.
    keeper/closees are local ticket IDs (4-hex UUIDs), not Jira keys —
    matches the enumerate_duplicate_anomalies contract that the apply
    path now consumes post-F2.
    """
    base = [
        {
            "jira_key": f"PROJ-{100 + i * 100}",
            "keeper": f"tick-{100 + i * 100:04d}",
            "closees": [f"tick-{200 + i * 100:04d}"],
            "labels": ["duplicate"],
        }
        for i in range(n)
    ]
    return base


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_apply_refuses_when_gate_fails(tmp_path, duplicates_band):
    """Apply returns exit code 1 and zero delete calls when gate fails (no attested.json)."""
    pass_id = "2026-05-22-dup-01"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # Write manifest but NO attestation — gate must fail
    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(2))

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    delete_log: list = []
    with (
        patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch(
            "duplicates_band.subprocess.run",
            side_effect=_make_subprocess_mock(delete_log=delete_log),
        ),
    ):
        rc = duplicates_band.cmd_apply(args, tmp_path)

    assert rc == 1
    assert delete_log == [], "Expected zero ticket-delete calls when gate fails"


def test_apply_deletes_duplicate_local_mappings(tmp_path, duplicates_band):
    """Apply runs `dso ticket delete` for each closee local ID and leaves Jira untouched.

    Post-F2: a duplicate set is N local mappings to ONE jira_key. The
    band deletes the N-1 closees (local IDs) via the ticket CLI; Jira
    has nothing to remediate (it owns one issue).
    """
    pass_id = "2026-05-22-dup-02"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [
        {
            "jira_key": "PROJ-100",
            "keeper": "tick-0100",
            "closees": ["tick-0200"],
            "labels": ["duplicate"],
        }
    ]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id, sha="abc123", acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    delete_log: list = []
    mock_fsck = _make_mock_fsck(post_pass_anomalies=[])

    with (
        patch.object(duplicates_band, "_load_fsck", return_value=mock_fsck),
        patch(
            "duplicates_band.subprocess.run",
            side_effect=_make_subprocess_mock(
                verify_returncode=0,
                committer_email="human@example.com",
                delete_log=delete_log,
            ),
        ),
    ):
        rc = duplicates_band.cmd_apply(args, tmp_path)

    assert rc == 0
    # The single closee was deleted; the keeper was NOT
    assert delete_log == ["tick-0200"], (
        f"Expected only tick-0200 deleted, got {delete_log}"
    )

    # Verify apply.log.json was written
    log_path = bootstrap_dir / f"duplicates-{pass_id}.apply.log.json"
    assert log_path.exists(), "apply.log.json was not written"


def test_apply_blocks_on_high_post_pass_count(tmp_path, duplicates_band):
    """Apply returns exit code 1 when post-pass count exceeds acknowledged_residual."""
    pass_id = "2026-05-22-dup-03"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = _make_sample_anomalies(2)
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    # acknowledged_residual=0 but post-pass returns 3 anomalies
    _write_attestation(bootstrap_dir, pass_id, sha="abc123", acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    mock_fsck = _make_mock_fsck(post_pass_anomalies=_make_sample_anomalies(3))

    with (
        patch.object(duplicates_band, "_load_fsck", return_value=mock_fsck),
        patch(
            "duplicates_band.subprocess.run",
            side_effect=_make_subprocess_mock(
                verify_returncode=0, committer_email="human@example.com"
            ),
        ),
    ):
        rc = duplicates_band.cmd_apply(args, tmp_path)

    assert rc == 1


def test_apply_records_per_set_outcomes(tmp_path, duplicates_band):
    """Apply writes apply.log.json with correct jira_key, keeper, closees, status fields."""
    pass_id = "2026-05-22-dup-04"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = [
        {
            "jira_key": "PROJ-100",
            "keeper": "tick-0100",
            "closees": ["tick-0200", "tick-0300"],
            "labels": ["duplicate"],
        }
    ]
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id, sha="abc123", acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    mock_fsck = _make_mock_fsck(post_pass_anomalies=[])

    with (
        patch.object(duplicates_band, "_load_fsck", return_value=mock_fsck),
        patch(
            "duplicates_band.subprocess.run",
            side_effect=_make_subprocess_mock(
                verify_returncode=0, committer_email="human@example.com"
            ),
        ),
    ):
        rc = duplicates_band.cmd_apply(args, tmp_path)

    assert rc == 0

    log_path = bootstrap_dir / f"duplicates-{pass_id}.apply.log.json"
    assert log_path.exists()
    outcomes = json.loads(log_path.read_text())
    assert len(outcomes) == 1

    outcome = outcomes[0]
    assert outcome["jira_key"] == "PROJ-100"
    assert outcome["keeper"] == "tick-0100"
    assert outcome["closees"] == ["tick-0200", "tick-0300"]
    assert outcome["status"] == "ok"


def test_apply_handles_gate_verification(tmp_path, duplicates_band):
    """Valid human attestation passes through gate to deletes; apply succeeds."""
    pass_id = "2026-05-22-dup-05"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = _make_sample_anomalies(1)
    _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(bootstrap_dir, pass_id, sha="validsha", acknowledged_residual=0)

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    delete_log: list = []
    mock_fsck = _make_mock_fsck(post_pass_anomalies=[])

    with (
        patch.object(duplicates_band, "_load_fsck", return_value=mock_fsck),
        patch(
            "duplicates_band.subprocess.run",
            side_effect=_make_subprocess_mock(
                verify_returncode=0,
                committer_email="human@example.com",
                delete_log=delete_log,
            ),
        ),
    ):
        rc = duplicates_band.cmd_apply(args, tmp_path)

    assert rc == 0
    # At least one local-ticket delete was issued (the closee from the sample)
    assert len(delete_log) > 0, "Expected at least one ticket-delete call"
