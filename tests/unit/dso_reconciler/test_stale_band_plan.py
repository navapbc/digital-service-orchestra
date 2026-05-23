"""RED tests for stale_band.py plan subcommand.

Story: "A stale-band plan materializes each stale anomaly via Jira property
reads and writes a manifest to bridge_state/bootstrap/stale-syncs-<pass>.manifest.json"
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
# Shared test data
# ---------------------------------------------------------------------------

_SAMPLE_STALE_ANOMALIES = [
    {
        "ticket_id": "tick-0001",
        "jira_key": "DSO-201",
        "last_sync_ts": 1_700_000_000_000_000_000,
        "class_label": "stale",
        "proposed_remediation": "re-sync or close",
    },
    {
        "ticket_id": "tick-0002",
        "jira_key": "DSO-202",
        "last_sync_ts": 1_700_000_000_000_000_000,
        "class_label": "stale",
        "proposed_remediation": "re-sync or close",
    },
    {
        "ticket_id": "tick-0003",
        "jira_key": "DSO-203",
        "last_sync_ts": 1_700_000_000_000_000_000,
        "class_label": "stale",
        "proposed_remediation": "re-sync or close",
    },
]

# Property values returned by mocked AcliClient.get_issue_property:
# DSO-201 → matches authoritative_local_id (tick-0001) → needs_review=False
# DSO-202 → matches authoritative_local_id (tick-0002) → needs_review=False
# DSO-203 → MISMATCHES authoritative_local_id (tick-0003) → needs_review=True
_PROPERTY_RESPONSES = {
    "DSO-201": "tick-0001",
    "DSO-202": "tick-0002",
    "DSO-203": "tick-DIFFERENT",  # ID-space boundary crossing
}


def _make_mock_fsck(anomalies=None):
    """Return a stub fsck module with enumerate_stale_anomalies returning controlled data."""
    if anomalies is None:
        anomalies = _SAMPLE_STALE_ANOMALIES

    mock_fsck = types.ModuleType("ticket_bridge_fsck")
    mock_fsck.enumerate_stale_anomalies = lambda _tickets_dir: list(anomalies)
    return mock_fsck


def _make_mock_acli(property_responses=None, raise_on=None):
    """Return a stub acli_integration module with a controllable AcliClient class.

    Args:
        property_responses: dict mapping jira_key → return value for get_issue_property.
        raise_on: jira_key that should trigger an exception from get_issue_property.
    """
    if property_responses is None:
        property_responses = _PROPERTY_RESPONSES

    class FakeAcliClient:
        def __init__(self, jira_url="", user="", api_token="", **kwargs):
            pass

        def get_issue_property(self, jira_key: str, property_key: str):
            if raise_on is not None and jira_key == raise_on:
                raise RuntimeError(f"ACLI error fetching property for {jira_key}")
            return property_responses.get(jira_key)

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = FakeAcliClient
    return mock_acli


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_plan_args(
    pass_id: str, repo_root: str, acli_url: str = "", acli_token: str = ""
):
    """Build an argparse.Namespace matching the 'plan' subcommand."""
    args = argparse.Namespace()
    args.command = "plan"
    args.pass_id = pass_id
    args.repo_root = repo_root
    args.acli_url = acli_url
    args.acli_token = acli_token
    return args


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_plan_writes_manifest(tmp_path, stale_band):
    """Manifest file is written with 3 anomaly entries."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-01", repo_root=str(tmp_path))

    with (
        patch.object(stale_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch.object(stale_band, "_load_acli", return_value=_make_mock_acli()),
    ):
        rc = stale_band.cmd_plan(args, tmp_path)

    assert rc == 0, f"cmd_plan returned non-zero exit code: {rc}"

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "stale-syncs-2026-05-22-01.manifest.json"
    )
    assert manifest_path.exists(), f"manifest not found at {manifest_path}"

    manifest = json.loads(manifest_path.read_text())
    assert manifest["pass_id"] == "2026-05-22-01"
    assert "anomalies" in manifest
    assert len(manifest["anomalies"]) == 3


def test_plan_boundary_crossing_flagged(tmp_path, stale_band):
    """Entry with mismatched current_property_id vs authoritative_local_id has needs_review=True."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-02", repo_root=str(tmp_path))

    with (
        patch.object(stale_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch.object(stale_band, "_load_acli", return_value=_make_mock_acli()),
    ):
        stale_band.cmd_plan(args, tmp_path)

    manifest_path = (
        tmp_path
        / "bridge_state"
        / "bootstrap"
        / "stale-syncs-2026-05-22-02.manifest.json"
    )
    manifest = json.loads(manifest_path.read_text())
    anomalies = manifest["anomalies"]

    # DSO-203 has current_property_id="tick-DIFFERENT" vs authoritative_local_id="tick-0003"
    dso203 = next(a for a in anomalies if a["jira_key"] == "DSO-203")
    assert dso203["needs_review"] is True, (
        f"DSO-203 should have needs_review=True (boundary crossing), got: {dso203}"
    )

    # DSO-201 and DSO-202 match — needs_review should be False
    dso201 = next(a for a in anomalies if a["jira_key"] == "DSO-201")
    assert dso201["needs_review"] is False, (
        f"DSO-201 should have needs_review=False (IDs match), got: {dso201}"
    )

    dso202 = next(a for a in anomalies if a["jira_key"] == "DSO-202")
    assert dso202["needs_review"] is False, (
        f"DSO-202 should have needs_review=False (IDs match), got: {dso202}"
    )


def test_plan_no_mutations(tmp_path, stale_band):
    """Plan is read-only: no write/set calls are made to Jira."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-03", repo_root=str(tmp_path))

    set_calls = []

    class FakeAcliClientNoWrite:
        def __init__(self, jira_url="", user="", api_token="", **kwargs):
            pass

        def get_issue_property(self, jira_key: str, property_key: str):
            return _PROPERTY_RESPONSES.get(jira_key)

        def set_issue_property(self, jira_key: str, property_key: str, value) -> None:
            set_calls.append((jira_key, property_key, value))

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = FakeAcliClientNoWrite

    with (
        patch.object(stale_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
    ):
        rc = stale_band.cmd_plan(args, tmp_path)

    assert rc == 0
    assert set_calls == [], f"plan made unexpected write calls to Jira: {set_calls}"


def test_plan_fails_on_acli_error(tmp_path, stale_band):
    """If get_issue_property raises, cmd_plan exits non-zero."""
    (tmp_path / ".tickets-tracker").mkdir()
    args = _make_plan_args(pass_id="2026-05-22-04", repo_root=str(tmp_path))

    # Raise on the first jira key encountered
    mock_acli = _make_mock_acli(raise_on="DSO-201")

    with (
        patch.object(stale_band, "_load_fsck", return_value=_make_mock_fsck()),
        patch.object(stale_band, "_load_acli", return_value=mock_acli),
    ):
        rc = stale_band.cmd_plan(args, tmp_path)

    assert rc != 0, "cmd_plan should return non-zero when get_issue_property raises"
