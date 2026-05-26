"""
Tests for the canonical telemetry event validator.

Schema: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md (schema_version=1)
Validates COMMON_FIELDS (11) + PER_TYPE_FIELDS (per event_type).
"""

from validator import validate_event

# Canonical 11 common fields with minimal valid values, plus the per-type
# fields for review_finding (the most field-heavy event type). Tests start
# from a known-valid base and mutate single fields to exercise each rule.
BASE_REVIEW_FINDING = {
    # 11 common fields
    "schema_version": 1,
    "event_id": "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
    "event_type": "review_finding",
    "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
    "tool_id": "dso",
    "tool_version": "1.17.11",
    "timestamp": "2026-05-22T14:30:00Z",
    # per-type review_finding fields
    "finding_id": "f-a1b2c3d4",
    "severity": "important",
    "category": "correctness",
    "description": "Off-by-one in index arithmetic.",
    "file": "src/processor.py",
    "cited_lines": ["src/processor.py:42"],
}

BASE_RESOLVER_OUTCOME = {
    **{k: v for k, v in BASE_REVIEW_FINDING.items() if k in {
        "schema_version", "event_id", "client_id", "tool_id", "tool_version", "timestamp",
    }},
    "event_type": "resolver_outcome",
    "finding_id": "f-a1b2c3d4",
    "resolution_action": "code_fix",
    "resolution_cycle": 1,
    "accepted": True,
}

BASE_REVIEW_CYCLE = {
    **{k: v for k, v in BASE_REVIEW_FINDING.items() if k in {
        "schema_version", "event_id", "client_id", "tool_id", "tool_version", "timestamp",
    }},
    "event_type": "review_cycle",
    "cycle_number": 1,
    "tier": "standard",
    "finding_count": 3,
    "critical_count": 0,
    "important_count": 1,
    "minor_count": 2,
    "pass": False,
    "resolution_attempts": 0,
    "diff_hash": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
}


# ── Common-field coverage ──────────────────────────────────────────────────────

def test_canonical_review_finding_passes():
    ok, err = validate_event(BASE_REVIEW_FINDING)
    assert ok and err is None, err


def test_missing_required_common_field_fails():
    payload = {k: v for k, v in BASE_REVIEW_FINDING.items() if k != "event_id"}
    ok, err = validate_event(payload)
    assert not ok and "event_id" in err


def test_missing_schema_version_fails():
    payload = {k: v for k, v in BASE_REVIEW_FINDING.items() if k != "schema_version"}
    ok, err = validate_event(payload)
    assert not ok and "schema_version" in err


def test_wrong_schema_version_fails():
    payload = {**BASE_REVIEW_FINDING, "schema_version": 2}
    ok, err = validate_event(payload)
    assert not ok and "schema_version" in err


def test_unknown_event_type_fails():
    payload = {**BASE_REVIEW_FINDING, "event_type": "made_up"}
    ok, err = validate_event(payload)
    assert not ok and "event_type" in err


def test_wrong_common_type_fails():
    payload = {**BASE_REVIEW_FINDING, "pr_number": "not-an-int"}
    ok, err = validate_event(payload)
    assert not ok and "pr_number" in err


def test_optional_common_field_omitted_passes():
    # All optional fields (pr_number, commit_sha, cycle, language) absent.
    payload = {k: v for k, v in BASE_REVIEW_FINDING.items()}
    ok, err = validate_event(payload)
    assert ok and err is None


def test_optional_common_field_present_with_correct_type_passes():
    payload = {**BASE_REVIEW_FINDING, "pr_number": 279, "commit_sha": "a" * 40, "cycle": 1, "language": "python"}
    ok, err = validate_event(payload)
    assert ok and err is None


# ── Per-event-type field coverage ──────────────────────────────────────────────

def test_review_finding_missing_per_type_field_fails():
    payload = {k: v for k, v in BASE_REVIEW_FINDING.items() if k != "finding_id"}
    ok, err = validate_event(payload)
    assert not ok and "finding_id" in err


def test_review_finding_invalid_severity_enum_fails():
    payload = {**BASE_REVIEW_FINDING, "severity": "blocker"}
    ok, err = validate_event(payload)
    assert not ok and "severity" in err


def test_resolver_outcome_canonical_passes():
    ok, err = validate_event(BASE_RESOLVER_OUTCOME)
    assert ok and err is None, err


def test_resolver_outcome_invalid_action_enum_fails():
    payload = {**BASE_RESOLVER_OUTCOME, "resolution_action": "ignored"}
    ok, err = validate_event(payload)
    assert not ok and "resolution_action" in err


def test_review_cycle_canonical_passes():
    ok, err = validate_event(BASE_REVIEW_CYCLE)
    assert ok and err is None, err


def test_review_cycle_pass_must_be_bool_not_int():
    payload = {**BASE_REVIEW_CYCLE, "pass": 0}
    ok, err = validate_event(payload)
    assert not ok and "pass" in err


def test_review_cycle_missing_diff_hash_fails():
    payload = {k: v for k, v in BASE_REVIEW_CYCLE.items() if k != "diff_hash"}
    ok, err = validate_event(payload)
    assert not ok and "diff_hash" in err


def test_tool_finding_canonical_passes():
    payload = {
        **{k: v for k, v in BASE_REVIEW_FINDING.items() if k in {
            "schema_version", "event_id", "client_id", "tool_id", "tool_version", "timestamp",
        }},
        "event_type": "tool_finding",
        "tool_name": "ruff",
        "tool_rule": "E501",
        "tool_severity": "error",
        "file": "src/processor.py",
        "message": "Line too long",
    }
    ok, err = validate_event(payload)
    assert ok and err is None, err


def test_arbiter_ruling_canonical_passes():
    payload = {
        **{k: v for k, v in BASE_REVIEW_FINDING.items() if k in {
            "schema_version", "event_id", "client_id", "tool_id", "tool_version", "timestamp",
        }},
        "event_type": "arbiter_ruling",
        "finding_id": "f-m3n4o5p6",
        "prior_finding_id": "f-a1b2c3d4",
        "arbiter_decision": "uphold",
        "arbiter_rationale": "Defense did not address root cause.",
    }
    ok, err = validate_event(payload)
    assert ok and err is None, err
