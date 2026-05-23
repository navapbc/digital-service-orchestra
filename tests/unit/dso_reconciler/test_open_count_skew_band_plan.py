"""Tests for open_count_skew_band.py plan subcommand."""

from __future__ import annotations

import argparse
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

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "open_count_skew_band.py"
)


def _load_module():
    spec = importlib.util.spec_from_file_location("open_count_skew_band", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["open_count_skew_band"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def open_count_skew_band():
    """Load the open_count_skew_band module, failing all tests if absent."""
    if not MODULE_PATH.exists():
        pytest.fail(
            f"open_count_skew_band.py not found at {MODULE_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Shared test data
# ---------------------------------------------------------------------------

_SAMPLE_ANOMALIES = [
    {"type": "task", "local_open": 10, "jira_open": 8, "delta": 2},
    {"type": "story", "local_open": 5, "jira_open": 3, "delta": 2},
]


def _make_mock_fsck(anomalies=None):
    """Return a stub fsck module with enumerate_open_count_skew_anomalies."""
    if anomalies is None:
        anomalies = _SAMPLE_ANOMALIES

    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_open_count_skew_anomalies = lambda _tickets_dir: list(anomalies)
    return mock_fsck


def _make_plan_args(pass_id: str, repo_root: str):
    """Build an argparse.Namespace matching the 'plan' subcommand."""
    args = argparse.Namespace()
    args.command = "plan"
    args.pass_id = pass_id
    args.repo_root = repo_root
    return args


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_plan_writes_manifest_with_type_skews(tmp_path, open_count_skew_band):
    """Manifest file is written with 2 anomaly entries (one per type)."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with patch.object(
        open_count_skew_band, "_load_fsck", return_value=_make_mock_fsck()
    ):
        rc = open_count_skew_band.cmd_plan(args, tmp_path)

    assert rc == 0, f"cmd_plan returned non-zero exit code: {rc}"

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "open-count-skew-2026-05-22-01.manifest.json"
    )
    assert manifest_path.exists(), f"manifest not found at {manifest_path}"

    manifest = json.loads(manifest_path.read_text())
    assert manifest["pass_id"] == "2026-05-22-01"
    assert "anomalies" in manifest
    assert len(manifest["anomalies"]) == 2


def test_manifest_contains_per_type_structure(tmp_path, open_count_skew_band):
    """Each anomaly entry has type, local_open, jira_open, delta fields."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-02", repo_root=str(tmp_path))

    with patch.object(
        open_count_skew_band, "_load_fsck", return_value=_make_mock_fsck()
    ):
        open_count_skew_band.cmd_plan(args, tmp_path)

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "open-count-skew-2026-05-22-02.manifest.json"
    )
    manifest = json.loads(manifest_path.read_text())
    anomalies = manifest["anomalies"]

    for anomaly in anomalies:
        assert "type" in anomaly, f"Missing 'type' field in anomaly: {anomaly}"
        assert "local_open" in anomaly, (
            f"Missing 'local_open' field in anomaly: {anomaly}"
        )
        assert "jira_open" in anomaly, (
            f"Missing 'jira_open' field in anomaly: {anomaly}"
        )
        assert "delta" in anomaly, f"Missing 'delta' field in anomaly: {anomaly}"


def test_plan_creates_output_dir_if_absent(tmp_path, open_count_skew_band):
    """Output directory is created when it does not pre-exist."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-03", repo_root=str(tmp_path))

    output_dir = tmp_path / "bridge_state" / "bootstrap"
    assert not output_dir.exists(), "Precondition: output dir must not pre-exist"

    with patch.object(
        open_count_skew_band, "_load_fsck", return_value=_make_mock_fsck()
    ):
        open_count_skew_band.cmd_plan(args, tmp_path)

    assert output_dir.exists(), f"Output directory was not created: {output_dir}"


def test_plan_exit_code_zero(tmp_path, open_count_skew_band):
    """cmd_plan returns 0 on success."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-04", repo_root=str(tmp_path))

    with patch.object(
        open_count_skew_band, "_load_fsck", return_value=_make_mock_fsck()
    ):
        rc = open_count_skew_band.cmd_plan(args, tmp_path)

    assert rc == 0


def test_plan_does_not_call_jira_mutations(tmp_path, open_count_skew_band):
    """Plan is read-only: no mutation calls are made via AcliClient."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-05", repo_root=str(tmp_path))

    mutation_calls = []

    class FakeAcliClient:
        def __init__(self, *a, **kw):
            pass

        def set_issue_property(self, jira_key, property_key, value):
            mutation_calls.append(("set_issue_property", jira_key, property_key, value))

        def update_issue_labels(self, jira_key, payload):
            mutation_calls.append(("update_issue_labels", jira_key, payload))

        def update_issue_property(self, jira_key, property_key, value):
            mutation_calls.append(
                ("update_issue_property", jira_key, property_key, value)
            )

    # open_count_skew_band.cmd_plan does not load acli at all — but patch the
    # module's namespace to be safe and confirm no mutation is triggered.
    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = FakeAcliClient

    with patch.object(
        open_count_skew_band, "_load_fsck", return_value=_make_mock_fsck()
    ):
        rc = open_count_skew_band.cmd_plan(args, tmp_path)

    assert rc == 0
    assert mutation_calls == [], (
        f"plan made unexpected mutation calls: {mutation_calls}"
    )
