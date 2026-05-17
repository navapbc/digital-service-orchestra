"""RED tests for dso_ci_review.arbiter BLOCK/DEFER/DROP cycle-end schema.

Testing mode: RED — arbiter module has old interface; new symbols not yet exported.
All tests MUST fail until arbiter.py is updated with the new interface.

Behavioral contracts under test:
1. dispatch_arbiter(findings, defenses, ..., cycle_num, max_cycles) returns a list of
   rulings with ruling in {BLOCK, DEFER, DROP}.
2. A critical undefended finding with cycle <= max_cycles yields ruling=BLOCK.
3. A finding with cycle > max_cycles yields ruling=DEFER (soft-cap exceeded).
4. validate_cycle_end_ruling raises ValueError when ruling is not in VALID_RULINGS
   (e.g., legacy ruling values not in the new schema are rejected).
"""

from __future__ import annotations

import sys
import pathlib
from unittest.mock import patch


# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.arbiter` resolves to the plugin source, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.arbiter import dispatch_arbiter, validate_cycle_end_ruling  # noqa: E402


# ---------------------------------------------------------------------------
# Test 1: BLOCK ruling returned for critical undefended finding within cycle cap
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_returns_block_when_critical_finding_undefended():
    """Given: finding severity=critical, no prior defense, cycle=1 <= max_cycles=4
    When: dispatch_arbiter called with mock returning BLOCK ruling
    Then: result is a list and result[0]["ruling"] == "BLOCK"
    """
    findings = [{"id": "f1", "severity": "critical"}]
    defenses = []
    diff_text = "--- a/auth/login.py\n+++ b/auth/login.py\n@@ -40,3 +40,4 @@ def login():\n+    if user is None:\n+        raise ValueError\n"
    model = "claude-sonnet-4-6"
    provider_chain = ["anthropic"]

    # Per agent contract: returns a JSON array of per-finding rulings.
    fake_rulings = [
        {
            "ruling": "BLOCK",
            "rationale": "Critical undefended finding blocks merge.",
            "schema_version": "1.0.0",
        }
    ]

    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_rulings):
        result = dispatch_arbiter(
            findings=findings,
            defenses=defenses,
            diff_text=diff_text,
            model=model,
            provider_chain=provider_chain,
            cycle_num=1,
            max_cycles=4,
        )

    assert isinstance(result, list), (
        f"Expected dispatch_arbiter to return a list, got {type(result)!r}"
    )
    assert result[0]["ruling"] == "BLOCK", (
        f"Expected ruling='BLOCK' for critical undefended finding, got {result[0]['ruling']!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: DEFER ruling returned when cycle exceeds max_cycles
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_returns_defer_when_cycle_exceeds_max():
    """Given: cycle=5 > max_cycles=4 (mock returns DEFER)
    When: dispatch_arbiter called
    Then: result[0]["ruling"] == "DEFER"
    """
    findings = [{"id": "f1", "severity": "critical"}]
    defenses = []
    diff_text = "--- a/auth/login.py\n+++ b/auth/login.py\n@@ -40,3 +40,4 @@ def login():\n+    if user is None:\n+        raise ValueError\n"
    model = "claude-sonnet-4-6"
    provider_chain = ["anthropic"]

    # Per agent contract: returns a JSON array of per-finding rulings.
    fake_rulings = [
        {
            "ruling": "DEFER",
            "rationale": "CoVe soft-cap: cycle exceeded max.",
            "schema_version": "1.0.0",
        }
    ]

    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_rulings):
        result = dispatch_arbiter(
            findings=findings,
            defenses=defenses,
            diff_text=diff_text,
            model=model,
            provider_chain=provider_chain,
            cycle_num=5,
            max_cycles=4,
        )

    assert isinstance(result, list), (
        f"Expected dispatch_arbiter to return a list, got {type(result)!r}"
    )
    assert result[0]["ruling"] == "DEFER", (
        f"Expected ruling='DEFER' when cycle exceeds max_cycles, got {result[0]['ruling']!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: validate_cycle_end_ruling raises ValueError for unknown ruling
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_raises_on_unknown_ruling():
    """Given: ruling dict with a legacy ruling value not in VALID_RULINGS
    When: validate_cycle_end_ruling(ruling) called
    Then: raises ValueError
    """
    import pytest

    # "SUSTAIN" is a legacy value from the old schema — must be rejected
    old_schema_ruling = {"ruling": "SUSTAIN", "rationale": "old schema"}

    with pytest.raises(ValueError):
        validate_cycle_end_ruling(old_schema_ruling)


# ---------------------------------------------------------------------------
# Test 4: dispatch_arbiter handles multi-finding rulings array per agent contract
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_handles_multi_finding_array():
    """Given: 3 input findings and mock returns a 3-element rulings array
    When: dispatch_arbiter called
    Then: returns a list of 3 validated rulings, each preserving its ruling,
          and CoVe fallback / validation are applied per ruling independently.
    """
    findings = [
        {"id": "f1", "severity": "critical"},
        {"id": "f2", "severity": "important"},
        {"id": "f3", "severity": "critical"},
    ]
    fake_rulings = [
        {"ruling": "BLOCK", "rationale": "first", "schema_version": "1.0.0"},
        {"ruling": "DEFER", "rationale": "second", "schema_version": "1.0.0"},
        {"ruling": "DROP", "rationale": "third", "schema_version": "1.0.0"},
    ]
    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_rulings):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=2,
            max_cycles=4,
        )

    assert len(result) == 3, f"Expected 3 rulings in result, got {len(result)}"
    assert result[0]["ruling"] == "BLOCK"
    assert result[1]["ruling"] == "DEFER"
    assert result[2]["ruling"] == "DROP"


# ---------------------------------------------------------------------------
# Test 5: dispatch_arbiter length-mismatch triggers fail-closed BLOCK synthesis
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_length_mismatch_triggers_fail_closed():
    """Given: 2 input findings (1 critical, 1 important) but mock returns only 1 ruling
    When: dispatch_arbiter called
    Then: returns fail-closed BLOCK rulings for all critical/important findings
          with rationale citing the length-mismatch.
    """
    findings = [
        {"id": "f1", "severity": "critical"},
        {"id": "f2", "severity": "important"},
    ]
    fake_rulings = [
        {"ruling": "DROP", "rationale": "only one returned", "schema_version": "1.0.0"},
    ]
    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_rulings):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )

    # All critical/important findings get fail-closed BLOCK
    assert all(r["ruling"] == "BLOCK" for r in result), (
        f"Expected all rulings to be BLOCK, got {[r['ruling'] for r in result]!r}"
    )
    assert all("length mismatch" in r["rationale"].lower() for r in result), (
        "Expected all rationales to cite length mismatch"
    )
