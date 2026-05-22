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

import json
import sys
import pathlib
from unittest.mock import patch


# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.arbiter` resolves to the plugin source, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.arbiter import (  # noqa: E402
    compute_ruling_from_fixture,
    dispatch_arbiter,
    validate_cycle_end_ruling,
)


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
    # AC amendment (review finding 4): synthetic rulings must preserve schema_version,
    # finding_index, and severity so downstream validation does not reject them.
    assert all(r.get("schema_version") == "1.0.0" for r in result), (
        f"Expected schema_version='1.0.0' on all synthetic rulings, got "
        f"{[r.get('schema_version') for r in result]!r}"
    )
    finding_indices = sorted(r.get("finding_index") for r in result)
    assert finding_indices == [0, 1], (
        f"Expected finding_index in {{0, 1}} matching input positions, got {finding_indices}"
    )
    severities = sorted(r.get("severity") for r in result)
    assert severities == ["critical", "important"], (
        f"Expected severities preserved from input findings, got {severities}"
    )


# ---------------------------------------------------------------------------
# Test 6: dispatch_arbiter dispatch-failure triggers fail-closed BLOCK synthesis
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_fail_closed_on_dispatch_failure(capsys):
    """Given: 3 findings (critical, important, minor) and dispatch_review raises ConnectionError
    When: dispatch_arbiter called
    Then: 2 synthetic BLOCK rulings (critical + important; minor skipped);
          severity preserved; structured stderr log emitted.
    """
    findings = [
        {"id": "f1", "severity": "critical", "finding_hash": "h1"},
        {"id": "f2", "severity": "important", "finding_hash": "h2"},
        {"id": "f3", "severity": "minor", "finding_hash": "h3"},
    ]

    def raise_dispatch(*args, **kwargs):
        raise ConnectionError("simulated network failure")

    with patch("dso_ci_review.arbiter.dispatch_review", side_effect=raise_dispatch):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )

    # 2 synthetic BLOCKs (critical + important); minor skipped
    assert len(result) == 2, (
        f"Expected 2 synthetic rulings (critical + important), got {len(result)}"
    )
    assert all(r["ruling"] == "BLOCK" for r in result), (
        f"Expected all rulings to be BLOCK, got {[r['ruling'] for r in result]!r}"
    )
    assert all("Arbiter dispatch failed" in r["rationale"] for r in result), (
        "Expected all rationales to cite 'Arbiter dispatch failed'"
    )
    assert all("ConnectionError" in r["rationale"] for r in result), (
        "Expected all rationales to cite the exception class name"
    )

    # Severity preserved in synthetic rulings (AC amendment)
    severities = [r.get("severity") for r in result]
    assert "critical" in severities, (
        f"Expected 'critical' in severities, got {severities}"
    )
    assert "important" in severities, (
        f"Expected 'important' in severities, got {severities}"
    )
    assert "minor" not in severities, (
        f"Minor finding should have been skipped, got severities={severities}"
    )

    # finding_hash preserved in synthetic rulings (AC amendment)
    hashes = [r.get("finding_hash") for r in result]
    assert "h1" in hashes and "h2" in hashes, (
        f"Expected original finding_hash values preserved, got {hashes}"
    )

    # AC amendment (review finding 4): synthetic rulings must also preserve
    # schema_version and finding_index so downstream validation does not reject them.
    assert all(r.get("schema_version") == "1.0.0" for r in result), (
        f"Expected schema_version='1.0.0' on synthetic rulings, got "
        f"{[r.get('schema_version') for r in result]!r}"
    )
    indices = sorted(r.get("finding_index") for r in result)
    assert indices == [0, 1], (
        f"Expected finding_index in {{0, 1}} matching input positions of "
        f"critical/important findings (minor at index 2 skipped), got {indices}"
    )

    # Structured stderr log
    captured = capsys.readouterr()
    assert "arbiter_dispatch_failed" in captured.err, (
        f"Expected 'arbiter_dispatch_failed' in stderr, got: {captured.err!r}"
    )
    assert "reason=ConnectionError" in captured.err, (
        f"Expected 'reason=ConnectionError' in stderr, got: {captured.err!r}"
    )
    assert "finding_count=3" in captured.err, (
        f"Expected 'finding_count=3' in stderr, got: {captured.err!r}"
    )


# ---------------------------------------------------------------------------
# Test 6b/6c: dispatch_arbiter fail-closed on CalledProcessError and JSONDecodeError
# (Review finding 3: _DISPATCH_FAILURE_EXCEPTIONS includes 3 types, test 6 only
# covered ConnectionError)
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_fail_closed_on_subprocess_error():
    """Given: dispatch_review raises subprocess.CalledProcessError
    When: dispatch_arbiter called
    Then: synthetic BLOCK rulings emitted for critical/important findings.
    """
    import subprocess

    findings = [
        {"id": "f1", "severity": "critical", "finding_hash": "h1"},
        {"id": "f2", "severity": "minor", "finding_hash": "h2"},
    ]

    def raise_called_process(*args, **kwargs):
        raise subprocess.CalledProcessError(returncode=1, cmd=["agent"], stderr="boom")

    with patch(
        "dso_ci_review.arbiter.dispatch_review", side_effect=raise_called_process
    ):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )

    assert len(result) == 1, (
        f"Expected 1 synthetic ruling (critical only), got {len(result)}"
    )
    assert result[0]["ruling"] == "BLOCK"
    assert "CalledProcessError" in result[0]["rationale"], (
        f"Expected rationale to cite CalledProcessError, got {result[0]['rationale']!r}"
    )


def test_dispatch_arbiter_fail_closed_on_json_decode_error():
    """Given: dispatch_review raises json.JSONDecodeError
    When: dispatch_arbiter called
    Then: synthetic BLOCK rulings emitted for critical/important findings.
    """
    import json as _json

    findings = [
        {"id": "f1", "severity": "important", "finding_hash": "hi"},
    ]

    def raise_json_decode(*args, **kwargs):
        raise _json.JSONDecodeError("bad json", "doc", 0)

    with patch("dso_ci_review.arbiter.dispatch_review", side_effect=raise_json_decode):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )

    assert len(result) == 1
    assert result[0]["ruling"] == "BLOCK"
    assert "JSONDecodeError" in result[0]["rationale"], (
        f"Expected rationale to cite JSONDecodeError, got {result[0]['rationale']!r}"
    )


# ---------------------------------------------------------------------------
# Test 7: dispatch_arbiter empty findings + dispatch failure → empty array
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_empty_findings_no_synthetic_block_on_dispatch_failure(capsys):
    """Given: empty findings list and dispatch_review would raise ConnectionError
    When: dispatch_arbiter called
    Then: returns empty array (no synthetic BLOCK for nonexistent findings).
          Short-circuit happens BEFORE dispatch, so dispatch_review is never called.
    """

    def raise_dispatch(*args, **kwargs):
        raise ConnectionError("network down")

    with patch(
        "dso_ci_review.arbiter.dispatch_review", side_effect=raise_dispatch
    ) as mock_dispatch:
        result = dispatch_arbiter(
            findings=[],
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )

    assert result == [], f"Expected empty rulings array, got {result!r}"
    # Dispatch should not have been called at all — empty findings short-circuit
    assert mock_dispatch.call_count == 0, (
        "Expected dispatch_review to be skipped entirely for empty findings"
    )


# ---------------------------------------------------------------------------
# Test 8: v1.1.0 cross_reviewer_agreement enum enforcement
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_enforces_cross_reviewer_agreement_enum():
    """Given: v1.1.0 ruling with a hallucinated cross_reviewer_agreement value
    When: validate_cycle_end_ruling(ruling) called
    Then: raises ValueError citing cross_reviewer_agreement
    """
    import pytest

    ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.1.0",
        "cross_reviewer_agreement": ["UNANIMOUS", "NOT_A_VALID_VALUE"],
        "cross_cycle_pattern": ["NEW_INTRODUCED"],
        "impact_class": "bug",
    }
    with pytest.raises(ValueError, match="cross_reviewer_agreement"):
        validate_cycle_end_ruling(ruling)


# ---------------------------------------------------------------------------
# Test 9: v1.1.0 cross_cycle_pattern enum enforcement
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_enforces_cross_cycle_pattern_enum():
    """Given: v1.1.0 ruling with a hallucinated cross_cycle_pattern value
    When: validate_cycle_end_ruling(ruling) called
    Then: raises ValueError citing cross_cycle_pattern
    """
    import pytest

    ruling = {
        "ruling": "DEFER",
        "rationale": "x",
        "schema_version": "1.1.0",
        "cross_reviewer_agreement": ["UNANIMOUS"],
        "cross_cycle_pattern": ["HALLUCINATED_PATTERN"],
        "impact_class": "bug",
    }
    with pytest.raises(ValueError, match="cross_cycle_pattern"):
        validate_cycle_end_ruling(ruling)


# ---------------------------------------------------------------------------
# Test 10: v1.1.0 impact_class enum enforcement
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_enforces_impact_class_enum():
    """Given: v1.1.0 ruling with a hallucinated impact_class value
    When: validate_cycle_end_ruling(ruling) called
    Then: raises ValueError citing impact_class
    """
    import pytest

    ruling = {
        "ruling": "DROP",
        "rationale": "x",
        "schema_version": "1.1.0",
        "cross_reviewer_agreement": ["UNANIMOUS"],
        "cross_cycle_pattern": ["NEW_INTRODUCED"],
        "impact_class": "made_up_category",
    }
    with pytest.raises(ValueError, match="impact_class"):
        validate_cycle_end_ruling(ruling)


# ---------------------------------------------------------------------------
# Test 11: v1.1.0 missing required fields → ValueError
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_rejects_missing_required_fields():
    """Given: v1.1.0 ruling missing the three required enriched fields
    When: validate_cycle_end_ruling(ruling) called
    Then: raises ValueError citing the missing field
    """
    import pytest

    ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.1.0",
        # Missing cross_reviewer_agreement, cross_cycle_pattern, impact_class
    }
    with pytest.raises(ValueError, match="missing"):
        validate_cycle_end_ruling(ruling)


# ---------------------------------------------------------------------------
# Test 12: backward compatibility — v1.0.0 (or absent schema_version) skips v1.1.0 checks
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_v1_0_0_legacy_does_not_require_v110_fields():
    """Given: v1.0.0 ruling (legacy) with no v1.1.0 enrichment fields
    When: validate_cycle_end_ruling(ruling) called
    Then: validates and returns unchanged (backward-compat)
    """
    ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.0.0",
        # No v1.1.0 fields — should still validate (backward compat)
    }
    result = validate_cycle_end_ruling(ruling)
    assert result == ruling, "v1.0.0 ruling should be returned unchanged"


# ---------------------------------------------------------------------------
# Test 13: v1.1.0 with all valid enum values passes
# ---------------------------------------------------------------------------


def test_validate_cycle_end_ruling_v1_1_0_with_valid_enum_values_passes():
    """Given: v1.1.0 ruling with all enum values drawn from the legal vocabularies
    When: validate_cycle_end_ruling(ruling) called
    Then: no exception is raised; returns the ruling unchanged
    """
    ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.1.0",
        "cross_reviewer_agreement": ["UNANIMOUS", "MAJORITY"],
        "cross_cycle_pattern": ["NEW_INTRODUCED", "RECURRING"],
        "impact_class": "security_vulnerability",
    }
    result = validate_cycle_end_ruling(ruling)
    assert result == ruling, "Valid v1.1.0 ruling should be returned unchanged"


# ---------------------------------------------------------------------------
# Test 14-17: impact_class 8-category floor enforcement (29e7-826e)
# ---------------------------------------------------------------------------


def test_block_ruling_with_impact_class_none_reclassified_to_defer():
    """BLOCK + impact_class='none' → DEFER reclassification."""
    from dso_ci_review.arbiter import _enforce_impact_class_floor

    ruling = {
        "ruling": "BLOCK",
        "rationale": "original reason",
        "schema_version": "1.1.0",
        "impact_class": "none",
        "cross_reviewer_agreement": ["UNANIMOUS"],
        "cross_cycle_pattern": ["NEW_INTRODUCED"],
    }
    result = _enforce_impact_class_floor(ruling)
    assert result["ruling"] == "DEFER"
    assert "impact_class floor" in result["rationale"]
    assert "original reason" in result["rationale"]  # preserves original


def test_block_ruling_with_impact_class_in_floor_preserved():
    """BLOCK + impact_class='security_vulnerability' (in floor) → BLOCK preserved."""
    from dso_ci_review.arbiter import _enforce_impact_class_floor

    ruling = {
        "ruling": "BLOCK",
        "rationale": "test",
        "schema_version": "1.1.0",
        "impact_class": "security_vulnerability",
        "cross_reviewer_agreement": ["UNANIMOUS"],
        "cross_cycle_pattern": ["NEW_INTRODUCED"],
    }
    result = _enforce_impact_class_floor(ruling)
    assert result["ruling"] == "BLOCK"
    assert result["rationale"] == "test"  # unchanged


def test_compute_ruling_from_fixture_applies_impact_class_floor():
    """Fixture with BLOCK + impact_class='none' → computed ruling reclassifies to DEFER."""
    fixture = {
        "arbiter_ruling": {
            "ruling": "BLOCK",
            "rationale": "BLOCK on minor",
            "schema_version": "1.1.0",
            "impact_class": "none",
            "cross_reviewer_agreement": ["UNANIMOUS"],
            "cross_cycle_pattern": ["NEW_INTRODUCED"],
        },
        "cycle": 1,
        "max_cycles": 4,
    }
    result = compute_ruling_from_fixture(fixture)
    assert result["ruling"] == "DEFER"
    assert "impact_class floor" in result["rationale"]


def test_block_ruling_v1_0_0_legacy_no_floor_check():
    """v1.0.0 ruling without impact_class field → no floor check applied (backward compat)."""
    from dso_ci_review.arbiter import _enforce_impact_class_floor

    ruling = {
        "ruling": "BLOCK",
        "rationale": "legacy",
        "schema_version": "1.0.0",
        # No impact_class field
    }
    result = _enforce_impact_class_floor(ruling)
    assert result["ruling"] == "BLOCK"  # unchanged for legacy


# ---------------------------------------------------------------------------
# DD7: dispatch_arbiter accepts reviewer_breakdown and ledger_history inputs
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_accepts_reviewer_breakdown_and_ledger_history():
    """Given: dispatch_arbiter called with the new DD7 optional inputs
    When: reviewer_breakdown + ledger_history are supplied
    Then: the call succeeds and returns rulings (params are accepted by signature)
    """
    findings = [{"id": "f1", "severity": "critical"}]
    reviewer_breakdown = {
        "f1": ["dso:code-reviewer-correctness", "dso:code-reviewer-hygiene"]
    }
    ledger_history = [
        {
            "cycle_num": 1,
            "schema_version": "1.1.0",
            "findings": [{"finding_hash": "abc"}],
        },
    ]
    fake_ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.1.0",
        "cross_reviewer_agreement": ["MAJORITY"],
        "cross_cycle_pattern": ["NEW_INTRODUCED"],
        "impact_class": "bug",
    }
    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_ruling):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
            reviewer_breakdown=reviewer_breakdown,
            ledger_history=ledger_history,
        )
    assert isinstance(result, list)
    assert result[0]["ruling"] == "BLOCK"


def test_dispatch_arbiter_defaults_when_dd7_inputs_omitted():
    """Given: dispatch_arbiter called without the new DD7 inputs (backward compat)
    When: reviewer_breakdown + ledger_history default to None
    Then: the call still succeeds (existing callers do not break)
    """
    findings = [{"id": "f1", "severity": "critical"}]
    fake_ruling = {
        "ruling": "BLOCK",
        "rationale": "x",
        "schema_version": "1.0.0",
    }
    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_ruling):
        result = dispatch_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
        )
    assert result[0]["ruling"] == "BLOCK"


def test_dispatch_cycle_end_arbiter_alias_threads_dd7_params():
    """Given: dispatch_cycle_end_arbiter (alias) called with DD7 inputs
    When: reviewer_breakdown + ledger_history are passed
    Then: the alias accepts them and delegates to dispatch_arbiter successfully
    """
    from dso_ci_review.arbiter import dispatch_cycle_end_arbiter

    findings = [{"id": "f1", "severity": "important"}]
    fake_ruling = {
        "ruling": "DEFER",
        "rationale": "x",
        "schema_version": "1.0.0",
    }
    with patch("dso_ci_review.arbiter.dispatch_review", return_value=fake_ruling):
        result = dispatch_cycle_end_arbiter(
            findings=findings,
            defenses=[],
            diff_text="diff",
            model="m",
            provider_chain=["anthropic"],
            cycle_num=5,
            max_cycles=4,
            reviewer_breakdown={"f1": ["dso:code-reviewer-correctness"]},
            ledger_history=[],
        )
    assert result[0]["ruling"] == "DEFER"


# ---------------------------------------------------------------------------
# Review finding 5: CoVe fallback + impact_class floor interaction.
# When cycle > max_cycles AND impact_class='none', both reclassifiers fire.
# Both reach DEFER, but the rationale should reflect which path was taken.
# ---------------------------------------------------------------------------


def test_block_ruling_cove_and_impact_class_floor_both_apply():
    """Given: BLOCK ruling with cycle_num=5 > max_cycles=4 AND impact_class='none'
    When: compute_ruling_from_fixture applies CoVe fallback then impact_class floor
    Then: final ruling is DEFER; both reclassifiers are idempotent (DEFER stays DEFER
          when fed back through floor enforcement); rationale records the first
          reclassification path that fired (CoVe, since it runs before floor).
    """
    from dso_ci_review.arbiter import compute_ruling_from_fixture

    fixture = {
        "arbiter_ruling": {
            "ruling": "BLOCK",
            "rationale": "original BLOCK rationale",
            "schema_version": "1.1.0",
            "impact_class": "none",
            "cross_reviewer_agreement": ["UNANIMOUS"],
            "cross_cycle_pattern": ["NEW_INTRODUCED"],
        },
        "cycle": 5,
        "max_cycles": 4,
    }
    result = compute_ruling_from_fixture(fixture)
    # Both CoVe (cycle 5 > max 4) and impact_class floor (impact_class='none')
    # independently reclassify BLOCK→DEFER. The combined outcome is DEFER.
    assert result["ruling"] == "DEFER", (
        f"Expected DEFER from combined CoVe + impact_class floor, got {result['ruling']!r}"
    )
    # The rationale should cite at least one of the two reclassification reasons.
    rationale_lower = result["rationale"].lower()
    assert (
        "cove" in rationale_lower
        or "max_cycles" in rationale_lower
        or "impact_class" in rationale_lower
    ), (
        f"Expected rationale to cite CoVe or impact_class floor, got {result['rationale']!r}"
    )


# ---------------------------------------------------------------------------
# Bug eb3d-f283: dispatch_arbiter must thread findings/defenses/
# reviewer_breakdown/ledger_history into the agent input via augmented
# diff_text so the arbiter agent can enumerate per-finding rulings.
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_forwards_findings_into_diff_text():
    """Given: dispatch_arbiter called with structured findings, defenses,
              reviewer_breakdown, and ledger_history payloads
    When: dispatch_review is patched to capture its diff_text argument
    Then: the captured diff_text contains parseable JSON blocks under their
          named section headers AND the parsed JSON preserves the input
          structure (ids, severities, defense rationales, reviewer mapping,
          cycle ledger entries) — proving the agent receives the full
          structured context, not just sentinel substrings.
    """
    findings = [
        {"id": "f1", "severity": "critical", "title": "sqli"},
        {"id": "f2", "severity": "important", "title": "race"},
        {"id": "f3", "severity": "minor", "title": "style"},
    ]
    defenses = [
        {"finding_id": "f1", "rationale": "false-positive context"},
    ]
    reviewer_breakdown = {"f1": ["reviewer-a", "reviewer-b"]}
    ledger_history = [{"cycle_num": 1, "findings_hash": "abc123"}]
    # Per agent contract: one ruling per finding (3 findings → 3 rulings).
    fake_rulings = [
        {"ruling": "BLOCK", "rationale": "r1", "schema_version": "1.0.0"},
        {"ruling": "DEFER", "rationale": "r2", "schema_version": "1.0.0"},
        {"ruling": "DROP", "rationale": "r3", "schema_version": "1.0.0"},
    ]

    with patch(
        "dso_ci_review.arbiter.dispatch_review", return_value=fake_rulings
    ) as mock_dispatch:
        dispatch_arbiter(
            findings=findings,
            defenses=defenses,
            diff_text="--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n",
            model="claude-sonnet-4-6",
            provider_chain=["anthropic"],
            cycle_num=1,
            max_cycles=4,
            reviewer_breakdown=reviewer_breakdown,
            ledger_history=ledger_history,
        )

    assert mock_dispatch.call_count == 1, (
        f"Expected dispatch_review called once, got {mock_dispatch.call_count}"
    )
    captured = mock_dispatch.call_args.kwargs["diff_text"]

    # Behavioral contract: each context block must be parseable JSON under
    # its named section header. Parsing (not substring match) defends against
    # accidental serialization regressions (e.g., str() instead of json.dumps,
    # truncation, escape corruption) that a substring assertion would miss.
    def _extract_json(section_header: str, text: str):
        """Locate a "## <section_header>" block and json.loads its payload."""
        idx = text.find(f"## {section_header}")
        assert idx != -1, f"Section header '## {section_header}' not in diff_text"
        # JSON starts at first '[' or '{' after the header.
        rest = text[idx + len(f"## {section_header}") :]
        start_obj = rest.find("{")
        start_arr = rest.find("[")
        candidates = [c for c in (start_obj, start_arr) if c != -1]
        assert candidates, f"No JSON payload after '## {section_header}'"
        start = min(candidates)
        # Greedy parse: keep extending until json.loads succeeds or we
        # reach the next '## ' header (whichever comes first).
        next_section = rest.find("\n## ", start)
        end = next_section if next_section != -1 else len(rest)
        return json.loads(rest[start:end].strip())

    # Findings: section heading includes cycle indicators, so search for the
    # canonical "Unresolved findings" prefix.
    findings_idx = captured.find("## Unresolved findings")
    assert findings_idx != -1, "Missing '## Unresolved findings' section"
    parsed_findings = _extract_json("Unresolved findings", captured)
    assert isinstance(parsed_findings, list), "findings payload must be a list"
    assert [f["id"] for f in parsed_findings] == ["f1", "f2", "f3"], (
        f"findings ids not preserved: {parsed_findings!r}"
    )
    assert [f["severity"] for f in parsed_findings] == [
        "critical",
        "important",
        "minor",
    ]

    parsed_defenses = _extract_json("Defenses", captured)
    assert isinstance(parsed_defenses, list)
    assert parsed_defenses[0]["finding_id"] == "f1"
    assert parsed_defenses[0]["rationale"] == "false-positive context"

    parsed_breakdown = _extract_json("Reviewer breakdown", captured)
    assert isinstance(parsed_breakdown, dict)
    assert parsed_breakdown["f1"] == ["reviewer-a", "reviewer-b"]

    parsed_ledger = _extract_json("Cycle ledger history", captured)
    assert isinstance(parsed_ledger, list)
    assert parsed_ledger[0]["cycle_num"] == 1
    assert parsed_ledger[0]["findings_hash"] == "abc123"
