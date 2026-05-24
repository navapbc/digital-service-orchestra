"""Tests for stale_band.py apply subcommand.

The apply subcommand runs gated stale SYNC anomaly mutations:
1. Inline gate check (attestation must be present and valid)
2. Per-anomaly label + property updates (skipping needs_review entries)
3. Post-pass count against acknowledged_residual / expected_residual
"""

from __future__ import annotations

import argparse
import hashlib
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
STALE_BAND_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "stale_band.py"
)


def _load_stale_band():
    spec = importlib.util.spec_from_file_location("stale_band", STALE_BAND_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["stale_band"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def stale_band():
    """Load the stale_band module, failing all tests if absent."""
    if not STALE_BAND_PATH.exists():
        pytest.fail(
            f"stale_band.py not found at {STALE_BAND_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_stale_band()


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
    mock_fsck.enumerate_stale_anomalies = MagicMock(
        return_value=list(post_pass_anomalies)
    )
    return mock_fsck


def _make_mock_acli(call_log: list | None = None) -> types.ModuleType:
    """Return a stub acli module whose AcliClient records method call order.

    The FakeAcliClient mirrors the real AcliClient constructor surface
    (kwargs jira_url/user/api_token/jira_project) so _build_acli_client
    can instantiate it without TypeError. Production callers route
    through _build_acli_client which validates JIRA_* env vars; tests
    set those vars via monkeypatch (or use this fake which ignores
    credentials entirely).
    """
    log = call_log if call_log is not None else []

    class _MockClient:
        def __init__(self, jira_url="", user="", api_token="", **kwargs):
            pass

        def add_label(self, jira_key, labels):
            log.append(("add_label", jira_key))

        def set_issue_property(self, jira_key, prop, value):
            log.append(("set_issue_property", jira_key))

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _MockClient
    return mock_acli


@pytest.fixture(autouse=True)
def _stale_apply_env(monkeypatch):
    """Provide JIRA_* env vars so _build_acli_client succeeds in tests."""
    monkeypatch.setenv("JIRA_URL", "https://jira.example/")
    monkeypatch.setenv("JIRA_USER", "test@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "test-token")
    monkeypatch.setenv("JIRA_PROJECT", "DIG")


def _write_manifest(
    bootstrap_dir: Path,
    pass_id: str,
    anomalies: list | None = None,
) -> Path:
    """Write a stale-syncs manifest JSON and return its path."""
    if anomalies is None:
        anomalies = []
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = bootstrap_dir / f"stale-syncs-{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps({"pass_id": pass_id, "anomalies": anomalies}))
    return manifest_path


def _write_attestation(
    bootstrap_dir: Path,
    pass_id: str,
    sha: str = "abc123",
    acknowledged_residual: int = 0,
    manifest_path: Path | None = None,
) -> Path:
    """Write a stale-syncs attested.json (with correct manifest hash) and return its path."""
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    attestation_path = bootstrap_dir / f"stale-syncs-{pass_id}.attested.json"
    data: dict = {
        "commit_sha": sha,
        "acknowledged_residual": acknowledged_residual,
    }
    if manifest_path is not None and manifest_path.exists():
        data["manifest_hash"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    attestation_path.write_text(json.dumps(data))
    return attestation_path


def _make_sample_anomalies(n: int, needs_review: bool = False) -> list[dict]:
    """Return a list of n minimal stale-sync anomaly dicts.

    Each anomaly carries a single label so cmd_apply's per-label add_label
    loop fires once per non-review anomaly. The actual label content is
    irrelevant for these tests; only the call count matters.
    """
    return [
        {
            "ticket_id": f"tick-{i:04d}",
            "jira_key": f"DSO-{200 + i}",
            "class_label": "stale_sync",
            "needs_review": needs_review,
            "labels": [f"stale-resolved-{i}"],
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_apply_refuses_when_gate_fails(tmp_path, stale_band):
    """Apply returns exit code 1 and makes zero AcliClient mutation calls when gate fails."""
    pass_id = "2026-05-22-stale-01"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # No attestation file written — gate must fail
    _write_manifest(bootstrap_dir, pass_id, anomalies=_make_sample_anomalies(2))

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            stale_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
        patch.object(stale_band, "_load_fsck", return_value=_make_mock_fsck()),
    ):
        rc = stale_band.cmd_apply(args, tmp_path)

    assert rc == 1
    assert call_log == [], "Expected zero AcliClient mutation calls when gate fails"


def test_apply_skips_needs_review_entries(tmp_path, stale_band):
    """Apply calls labels+property for clean entries and skips needs_review ones."""
    pass_id = "2026-05-22-stale-02"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # 3 entries: 2 clean, 1 needs_review
    anomalies = _make_sample_anomalies(2, needs_review=False) + _make_sample_anomalies(
        1, needs_review=True
    )
    manifest_path = _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(
        bootstrap_dir, pass_id, sha="deadbeef", manifest_path=manifest_path
    )

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            stale_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
        patch.object(
            stale_band,
            "_load_fsck",
            return_value=_make_mock_fsck(post_pass_anomalies=[]),
        ),
    ):
        rc = stale_band.cmd_apply(args, tmp_path)

    assert rc == 0

    # 2 clean entries × 2 calls each = 4 total; 1 needs_review entry → 0 calls
    labels_calls = [c for c in call_log if c[0] == "add_label"]
    prop_calls = [c for c in call_log if c[0] == "set_issue_property"]
    assert len(labels_calls) == 2
    assert len(prop_calls) == 2

    # Verify applied.json records 2 applied, 1 skipped
    applied_path = bootstrap_dir / f"stale-syncs-{pass_id}.applied.json"
    assert applied_path.exists()
    result = json.loads(applied_path.read_text())
    assert len(result["applied"]) == 2
    assert len(result["skipped"]) == 1


def test_apply_calls_labels_before_property(tmp_path, stale_band):
    """For each non-review entry, add_label is called before set_issue_property."""
    pass_id = "2026-05-22-stale-03"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    anomalies = _make_sample_anomalies(2, needs_review=False)
    manifest_path = _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(
        bootstrap_dir, pass_id, sha="deadbeef", manifest_path=manifest_path
    )

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)

    with (
        patch.object(
            stale_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
        patch.object(
            stale_band,
            "_load_fsck",
            return_value=_make_mock_fsck(post_pass_anomalies=[]),
        ),
    ):
        stale_band.cmd_apply(args, tmp_path)

    # Verify interleaved order: labels, property, labels, property (one pair per entry)
    assert len(call_log) == 4
    assert call_log[0][0] == "add_label"
    assert call_log[1][0] == "set_issue_property"
    assert call_log[2][0] == "add_label"
    assert call_log[3][0] == "set_issue_property"


def test_apply_blocks_on_high_post_pass_count(tmp_path, stale_band):
    """Apply returns exit code 1 when post-pass count exceeds both acknowledged_residual and skipped."""
    pass_id = "2026-05-22-stale-04"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # 2 clean anomalies, acknowledged_residual=0, no skipped
    anomalies = _make_sample_anomalies(2, needs_review=False)
    manifest_path = _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(
        bootstrap_dir,
        pass_id,
        sha="deadbeef",
        acknowledged_residual=0,
        manifest_path=manifest_path,
    )

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)
    # Post-pass returns 3 anomalies — more than max(0, 0)=0
    mock_fsck = _make_mock_fsck(post_pass_anomalies=_make_sample_anomalies(3))

    with (
        patch.object(
            stale_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
        patch.object(stale_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = stale_band.cmd_apply(args, tmp_path)

    assert rc == 1


def test_apply_succeeds_when_post_pass_within_residual(tmp_path, stale_band):
    """Apply returns exit code 0 when post-pass count equals len(skipped)."""
    pass_id = "2026-05-22-stale-05"
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"

    # 2 clean + 1 needs_review → expected_residual=1
    anomalies = _make_sample_anomalies(2, needs_review=False) + _make_sample_anomalies(
        1, needs_review=True
    )
    manifest_path = _write_manifest(bootstrap_dir, pass_id, anomalies=anomalies)
    _write_attestation(
        bootstrap_dir,
        pass_id,
        sha="deadbeef",
        acknowledged_residual=0,
        manifest_path=manifest_path,
    )

    args = _make_apply_args(pass_id=pass_id, repo_root=str(tmp_path))

    call_log: list = []
    mock_acli = _make_mock_acli(call_log)
    # Post-pass returns exactly 1 anomaly == len(skipped)
    mock_fsck = _make_mock_fsck(post_pass_anomalies=_make_sample_anomalies(1))

    with (
        patch.object(
            stale_band, "_load_attestation", return_value=_make_mock_attestation(True)
        ),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
        patch.object(stale_band, "_load_fsck", return_value=mock_fsck),
    ):
        rc = stale_band.cmd_apply(args, tmp_path)

    assert rc == 0
