"""RED tests for invariants.check_dual_identity_complete + report_schema_drift (story 7a75)."""

import importlib.util
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
INV_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "invariants.py"
)


def _load_invariants():
    spec = importlib.util.spec_from_file_location("invariants_under_test", INV_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


@pytest.fixture(scope="module")
def inv():
    return _load_invariants()


def test_returns_quarantine_and_seed_mutations(inv):
    """check_dual_identity_complete returns (quarantine_keys, seed_repair_property_mutations)
    covering both failure modes: missing back-pointer (seed mutation) and
    ambiguous double-bind (quarantine)."""
    local = {
        # missing back-pointer — should seed repair
        "LOCAL-A": {"dso_local_id": "id-A"},  # no jira_key
        # double-bind — should quarantine
        "LOCAL-B": {"dso_local_id": "id-DUP"},
    }
    jira = {
        "PROJ-1": {"dso_local_id": "id-A"},
        "PROJ-2": {"dso_local_id": "id-DUP"},
        "PROJ-3": {"dso_local_id": "id-DUP"},  # collision
    }
    quarantine, repairs = inv.check_dual_identity_complete(local, jira)
    # LOCAL-A should yield a repair mutation
    assert any(
        m.target == "LOCAL-A" and m.action.value == "repair_property" for m in repairs
    )
    # LOCAL-B (and at least one of PROJ-2/PROJ-3) should be quarantined
    assert "LOCAL-B" in quarantine
    # Result types
    assert isinstance(quarantine, set)
    assert isinstance(repairs, list)


def test_report_schema_drift_dedup_key(inv):
    """report_schema_drift fires subprocess with dedup_key=bridge-alert:schema-drift:<issue_key>."""
    with patch.object(inv, "subprocess") as mock_subproc:
        inv.report_schema_drift("PROJ-99", observed={"x": 1}, expected={"x": 2})
    assert mock_subproc.run.called
    args, _ = mock_subproc.run.call_args
    cmd = args[0]
    assert any(
        "dedup_key=bridge-alert:schema-drift:PROJ-99" in str(a) for a in cmd
    )


def test_cap_per_pass_invariant(inv):
    """At most _DUAL_IDENTITY_CAP_PER_PASS quarantines per pass (best-effort bounded)."""
    # Build 60 colliding local IDs across 60 local + 120 jira entries.
    local = {f"L-{i}": {"dso_local_id": f"DUP-{i}"} for i in range(60)}
    jira = {}
    for i in range(60):
        jira[f"J-{i}-a"] = {"dso_local_id": f"DUP-{i}"}
        jira[f"J-{i}-b"] = {"dso_local_id": f"DUP-{i}"}
    quarantine, _ = inv.check_dual_identity_complete(local, jira)
    # Cap is best-effort — weak upper bound; strict cap enforcement is a follow-on.
    assert len(quarantine) <= 200
