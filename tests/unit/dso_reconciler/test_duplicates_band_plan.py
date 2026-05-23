"""Tests for duplicates_band.py plan subcommand.

Story: "A duplicates-band plan enumerates duplicate anomalies and writes a
manifest to bridge_state/bootstrap/duplicates-<pass>.manifest.json"
"""

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
# Shared test data
# ---------------------------------------------------------------------------

_SAMPLE_DUPLICATE_ANOMALIES = [
    {
        "jira_key": "DSO-101",
        "ticket_ids": ["tick-aaa1", "tick-aaa2"],
        "class_label": "duplicate",
        "proposed_remediation": "close newer duplicates",
        "keeper": "tick-aaa1",
        "closees": ["tick-aaa2"],
    },
    {
        "jira_key": "DSO-102",
        "ticket_ids": ["tick-bbb1", "tick-bbb2", "tick-bbb3"],
        "class_label": "duplicate",
        "proposed_remediation": "close newer duplicates",
        "keeper": "tick-bbb1",
        "closees": ["tick-bbb2", "tick-bbb3"],
    },
]


def _make_mock_fsck(anomalies=None):
    """Return a stub fsck module with enumerate_duplicate_anomalies returning controlled data."""
    if anomalies is None:
        anomalies = _SAMPLE_DUPLICATE_ANOMALIES

    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_duplicate_anomalies = lambda _tickets_dir: list(anomalies)
    return mock_fsck


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


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


def test_plan_writes_manifest_with_duplicate_sets(tmp_path, duplicates_band):
    """Manifest file is written with 2 anomaly entries."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()):
        rc = duplicates_band.cmd_plan(args, tmp_path)

    assert rc == 0, f"cmd_plan returned non-zero exit code: {rc}"

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "duplicates-2026-05-22-01.manifest.json"
    )
    assert manifest_path.exists(), f"manifest not found at {manifest_path}"

    manifest = json.loads(manifest_path.read_text())
    assert manifest["pass_id"] == "2026-05-22-01"
    assert "anomalies" in manifest
    assert len(manifest["anomalies"]) == 2


def test_manifest_contains_required_fields(tmp_path, duplicates_band):
    """Each anomaly in the manifest has all required fields."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-02", repo_root=str(tmp_path))

    with patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()):
        duplicates_band.cmd_plan(args, tmp_path)

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "duplicates-2026-05-22-02.manifest.json"
    )
    manifest = json.loads(manifest_path.read_text())
    required_fields = {
        "jira_key",
        "ticket_ids",
        "class_label",
        "proposed_remediation",
        "keeper",
        "closees",
    }

    for anomaly in manifest["anomalies"]:
        missing = required_fields - set(anomaly.keys())
        assert not missing, (
            f"Anomaly {anomaly.get('jira_key', '?')} missing fields: {missing}"
        )


def test_plan_creates_output_dir_if_absent(tmp_path, duplicates_band):
    """Output directory is created if it does not pre-exist."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-03", repo_root=str(tmp_path))

    output_dir = tmp_path / "bridge_state" / "bootstrap"
    assert not output_dir.exists(), "Output dir should not exist before cmd_plan"

    with patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()):
        duplicates_band.cmd_plan(args, tmp_path)

    assert output_dir.exists(), "cmd_plan should create the output directory"


def test_plan_exit_code_zero(tmp_path, duplicates_band):
    """cmd_plan returns 0 on success."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-04", repo_root=str(tmp_path))

    with patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()):
        rc = duplicates_band.cmd_plan(args, tmp_path)

    assert rc == 0


def test_plan_does_not_call_jira_mutations(tmp_path, duplicates_band):
    """Plan is read-only: no mutating methods are called on AcliClient."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-05", repo_root=str(tmp_path))

    mutation_calls = []

    class FakeAcliClient:
        def __init__(self, *a, **kw):
            pass

        def set_issue_property(self, jira_key, property_key, value):
            mutation_calls.append(("set_issue_property", jira_key, property_key))

        def create_issue(self, *a, **kw):
            mutation_calls.append(("create_issue",))

        def update_issue(self, *a, **kw):
            mutation_calls.append(("update_issue",))

        def transition_issue(self, *a, **kw):
            mutation_calls.append(("transition_issue",))

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = FakeAcliClient

    with (
        patch.object(duplicates_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch.dict(sys.modules, {"acli_integration": mock_acli}),
    ):
        rc = duplicates_band.cmd_plan(args, tmp_path)

    assert rc == 0
    assert mutation_calls == [], (
        f"cmd_plan made unexpected mutating calls: {mutation_calls}"
    )
