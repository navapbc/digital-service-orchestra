"""Contract tests: emit_event must serialise all PER_TYPE_FIELDS required by
the canonical telemetry schema into the telemetry-emit.sh argv.

This file is the regression guard for the d2f9 recovery PR's finding #1:
runner.py and arbiter_processor.py emit call sites were authored against an
informal schema and silently dropped required fields (e.g. emitting
review_finding without finding_id/severity/category, or review_cycle without
cycle_number/tier/finding_count). The Lambda validator would have rejected
every such call with HTTP 400, but the fire-and-forget wrapper swallows that
rejection — so the broken pipeline looked wired in CI.

These tests enforce, at the wrapper boundary, that when a caller passes the
documented PER_TYPE_FIELDS for a given event_type, the wrapper actually
forwards them all into the subprocess argv. A future schema-drift in any
emit call site is caught by the runner/arbiter integration tests below; the
field-mapping tests at the bottom of this file ensure the wrapper itself
doesn't silently drop or rename a field on the way to the shim.

Schema source of truth:
${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/lambda-handler/schema.py
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest

# Required PER_TYPE_FIELDS per canonical schema (must match
# lambda-handler/schema.py PER_TYPE_FIELDS verbatim).
REQUIRED_PER_TYPE_FIELDS: dict[str, set[str]] = {
    "review_finding": {
        "finding_id",
        "severity",
        "category",
        "description",
        "file",
        "cited_lines",
    },
    "resolver_outcome": {
        "finding_id",
        "resolution_action",
        "resolution_cycle",
        "accepted",
    },
    "arbiter_ruling": {
        "finding_id",
        "prior_finding_id",
        "arbiter_decision",
        "arbiter_rationale",
    },
    "tool_finding": {
        "tool_name",
        "tool_rule",
        "tool_severity",
        "file",
        "message",
    },
    "review_cycle": {
        "cycle_number",
        "tier",
        "finding_count",
        "critical_count",
        "important_count",
        "minor_count",
        "pass",
        "resolution_attempts",
        "diff_hash",
    },
}


# Sample valid payload per event_type (enum-constrained fields use a legal
# enum value; unconstrained fields use plausible strings/ints).
SAMPLE_KWARGS: dict[str, dict[str, object]] = {
    "review_finding": {
        "finding_id": "sample-finding-001",
        "severity": "minor",
        "category": "correctness",
        "description": "sample description",
        "file": "plugins/dso/scripts/foo.py",
        "cited_lines": ["plugins/dso/scripts/foo.py:42"],
    },
    "resolver_outcome": {
        "finding_id": "sample-finding-001",
        "resolution_action": "defense",
        "resolution_cycle": 2,
        "accepted": False,
    },
    "arbiter_ruling": {
        "finding_id": "sample-finding-001",
        "prior_finding_id": "sample-finding-001",
        "arbiter_decision": "uphold",
        "arbiter_rationale": "ruling_type=BLOCK",
    },
    "tool_finding": {
        "tool_name": "dso-llm-review",
        "tool_rule": "specialist_error",
        "tool_severity": "warning",
        "file": "plugins/dso/scripts/foo.py",
        "message": "sample message",
    },
    "review_cycle": {
        "cycle_number": 2,
        "tier": "deep",
        "finding_count": 5,
        "critical_count": 0,
        "important_count": 1,
        "minor_count": 4,
        "pass": False,
        "resolution_attempts": 1,
        "diff_hash": "abc123",
    },
}


def test_autouse_telemetry_disable_is_overridable_per_test(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Regression guard for the `_dso_disable_telemetry_during_tests` autouse
    fixture's override contract.

    The fixture in tests/conftest.py sets DSO_TELEMETRY_DISABLE=1 for every
    test in the session to prevent live emits. Tests that intentionally
    exercise the wrapper (the parametrised test below, plus the wrapper-
    specific tests in test_telemetry_emit_wrapper.py) call
    ``monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)`` and rely
    on the documented pytest fixture-application order — autouse first, then
    per-test monkeypatch — for the delenv to actually take effect.

    If pytest semantics ever change, or if a developer adds a session-scoped
    monkeypatch that runs after the autouse fixture, the per-test override
    would silently fail and the wrapper tests would pass while no longer
    exercising the real emit path. This test fires in that case: it
    explicitly observes the env var set by the autouse fixture, runs
    delenv, and asserts the var is gone.
    """
    # When this test begins, the autouse fixture has already set the env var.
    assert os.environ.get("DSO_TELEMETRY_DISABLE") == "1", (
        "_dso_disable_telemetry_during_tests autouse fixture did not run "
        "before this test — pytest fixture order may have changed."
    )
    # Per-test override must succeed.
    monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
    assert "DSO_TELEMETRY_DISABLE" not in os.environ, (
        "monkeypatch.delenv() failed to remove DSO_TELEMETRY_DISABLE — "
        "the autouse fixture's setenv is winning over per-test cleanup, "
        "which would break every test in test_telemetry_emit_wrapper.py "
        "that exercises the real emit path."
    )


def _argv_from_emit(event_type: str, **kwargs) -> list[str]:
    """Call telemetry_emit_wrapper.emit_event with kwargs while mocking
    subprocess.Popen; return the argv list the wrapper would have spawned."""
    from dso_ci_review import telemetry_emit_wrapper as wrapper

    captured: list[list[str]] = []

    class _FakeProc:
        def poll(self):
            return 0

    def _fake_popen(argv, *args, **proc_kwargs):
        captured.append(list(argv))
        return _FakeProc()

    with patch.object(wrapper.subprocess, "Popen", side_effect=_fake_popen):
        wrapper.emit_event(event_type, **kwargs)

    assert len(captured) == 1, (
        f"emit_event(event_type={event_type!r}) made {len(captured)} Popen "
        f"calls; expected exactly 1"
    )
    return captured[0]


def _payload_field_keys(argv: list[str]) -> set[str]:
    """Extract the set of payload-field keys serialised into argv by the
    wrapper's `--payload-field key=value` forwarder."""
    keys: set[str] = set()
    for i, token in enumerate(argv):
        if token == "--payload-field" and i + 1 < len(argv):
            kv = argv[i + 1]
            if "=" in kv:
                keys.add(kv.split("=", 1)[0])
    return keys


# ---------------------------------------------------------------------------
# Wrapper contract: every required PER_TYPE_FIELD reaches argv
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("event_type", sorted(REQUIRED_PER_TYPE_FIELDS.keys()))
def test_emit_event_forwards_all_required_per_type_fields(
    event_type: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """For every canonical event_type, emit_event must forward every required
    PER_TYPE_FIELD into the subprocess argv as a `--payload-field key=value`
    pair. This catches the regression class where a caller forgets to pass a
    required field — the field-name set in argv after wrapper serialisation
    must be a superset of REQUIRED_PER_TYPE_FIELDS[event_type]."""
    # Disable the DSO_TELEMETRY_DISABLE bypass so emit_event actually spawns.
    monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
    argv = _argv_from_emit(event_type, **SAMPLE_KWARGS[event_type])

    # event_type must always be the first --event-type pair.
    assert "--event-type" in argv, f"argv missing --event-type: {argv}"
    et_idx = argv.index("--event-type")
    assert argv[et_idx + 1] == event_type, (
        f"--event-type carried {argv[et_idx + 1]!r}, expected {event_type!r}"
    )

    # Every required PER_TYPE_FIELD must appear as a --payload-field key.
    serialised_keys = _payload_field_keys(argv)
    missing = REQUIRED_PER_TYPE_FIELDS[event_type] - serialised_keys
    assert not missing, (
        f"emit_event(event_type={event_type!r}) dropped required "
        f"PER_TYPE_FIELDS from argv: {sorted(missing)}. "
        f"Argv keys present: {sorted(serialised_keys)}"
    )


# ---------------------------------------------------------------------------
# Runner integration: review_finding, tool_finding, and review_cycle emit shapes
# ---------------------------------------------------------------------------
#
# These tests call the production emit helpers directly (with an injected
# emit_fn that captures kwargs) rather than replicating their bodies. A future
# regression in the helper — e.g. dropping a required PER_TYPE_FIELD, or
# changing an enum value off-schema — fires the assertion here because we are
# exercising the same code path that runs in CI.


def test_runner_emit_finding_dispatches_review_finding_with_required_fields() -> None:
    """_emit_finding_telemetry must emit a review_finding event for a real
    LLM finding (type not in _TOOL_FINDING_TYPES) carrying every required
    PER_TYPE_FIELD."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []
    finding = {
        "type": "review_finding",
        "finding_id": "f-001",
        "severity": "important",
        "category": "correctness",
        "description": "missing None check",
        "file": "foo.py",
        "cited_lines": ["foo.py:42"],
    }
    runner._emit_finding_telemetry(
        finding,
        finding_idx=0,
        cycle_number=2,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "review_finding"
    missing = REQUIRED_PER_TYPE_FIELDS["review_finding"] - set(kwargs.keys())
    assert not missing, f"review_finding emit dropped fields: {sorted(missing)}"
    # Enum normalisation: severity / category must land on the canonical enum.
    assert kwargs["severity"] in {"critical", "important", "minor", "suggestion"}
    assert kwargs["category"] in {
        "correctness",
        "design",
        "hygiene",
        "maintainability",
        "verification",
    }


def test_runner_emit_finding_dispatches_tool_finding_for_operational_types() -> None:
    """_emit_finding_telemetry must emit a tool_finding event for operational
    finding types (specialist_error / fallback_exhausted / parse_error /
    tool_finding) carrying every required PER_TYPE_FIELD."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []
    finding = {
        "type": "specialist_error",
        "severity": "important",
        "file": "",
        "description": "specialist timeout",
    }
    runner._emit_finding_telemetry(
        finding,
        finding_idx=3,
        cycle_number=1,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "tool_finding"
    missing = REQUIRED_PER_TYPE_FIELDS["tool_finding"] - set(kwargs.keys())
    assert not missing, f"tool_finding emit dropped fields: {sorted(missing)}"
    # tool_severity must land on the canonical 3-bucket enum.
    assert kwargs["tool_severity"] in {"error", "warning", "info"}


@pytest.mark.parametrize(
    "raw_severity,expected",
    [
        # Canonical enum passthroughs.
        ("critical", "critical"),
        ("important", "important"),
        ("minor", "minor"),
        ("suggestion", "suggestion"),
        # Every documented alias must be covered so a regression in the
        # alias table fires the test rather than silently downgrading the
        # severity at the Lambda boundary.
        ("high", "important"),
        ("fragile", "important"),  # DSO-internal severity, must map to important
        ("medium", "minor"),
        ("low", "minor"),
        ("info", "suggestion"),
        ("informational", "suggestion"),
        # Case insensitivity.
        ("CRITICAL", "critical"),
        ("Important", "important"),
        ("  minor  ", "minor"),  # whitespace stripped
        # Fallback paths.
        ("UNKNOWN-LEVEL", "minor"),
        ("", "minor"),
        (None, "minor"),
        (42, "minor"),  # non-string types
    ],
)
def test_runner_normalise_review_severity(raw_severity, expected) -> None:
    """_normalise_review_severity must map raw values to the canonical enum,
    with alias and fallback behaviour matching the documented contract."""
    from dso_ci_review import runner

    assert runner._normalise_review_severity(raw_severity) == expected


@pytest.mark.parametrize(
    "raw_category,expected",
    [
        # Canonical enum passthroughs.
        ("correctness", "correctness"),
        ("design", "design"),
        ("hygiene", "hygiene"),
        ("maintainability", "maintainability"),
        ("verification", "verification"),
        # Every documented alias.
        ("performance", "correctness"),
        ("security", "correctness"),
        ("style", "hygiene"),
        ("documentation", "maintainability"),
        ("test", "verification"),
        ("tests", "verification"),
        # Case + whitespace handling.
        ("DESIGN", "design"),
        ("  hygiene  ", "hygiene"),
        # Fallbacks.
        ("unknown-category", "correctness"),
        ("", "correctness"),
        (None, "correctness"),
        (42, "correctness"),
    ],
)
def test_runner_normalise_review_category(raw_category, expected) -> None:
    """_normalise_review_category must map raw values to the canonical enum,
    with documented aliases and a safe fallback to 'correctness'."""
    from dso_ci_review import runner

    assert runner._normalise_review_category(raw_category) == expected


@pytest.mark.parametrize(
    "raw_severity,expected",
    [
        # Each review-severity bucket maps to one of the 3 tool-severity buckets.
        ("critical", "error"),
        ("important", "warning"),
        ("minor", "info"),
        ("suggestion", "info"),
        # Case-insensitive matching.
        ("CRITICAL", "error"),
        ("  important  ", "warning"),
        # Unknown / missing fallback.
        ("fragile", "info"),  # not in the 3-bucket map; falls back
        ("", "info"),
        (None, "info"),
        (42, "info"),
    ],
)
def test_runner_normalise_tool_severity(raw_severity, expected) -> None:
    """_normalise_tool_severity must collapse the 4-bucket review enum into
    the 3-bucket tool_finding enum (error/warning/info), with safe fallback
    for unknown inputs."""
    from dso_ci_review import runner

    assert runner._normalise_tool_severity(raw_severity) == expected


def test_runner_emit_review_cycle_with_empty_findings() -> None:
    """The first-cycle clean-review state: empty findings list must still
    produce a schema-valid review_cycle emit with pass=True and zero counts."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []
    runner._emit_review_cycle_telemetry(
        [],
        cycle_number=1,
        tier="light",
        reviewed_sha="0000000000000000000000000000000000000000",
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "review_cycle"
    missing = REQUIRED_PER_TYPE_FIELDS["review_cycle"] - set(kwargs.keys())
    assert not missing
    assert kwargs["finding_count"] == 0
    assert kwargs["critical_count"] == 0
    assert kwargs["important_count"] == 0
    assert kwargs["minor_count"] == 0
    assert kwargs["pass"] is True
    assert kwargs["resolution_attempts"] == 0


def test_arbiter_emit_uses_synthetic_finding_id_when_missing() -> None:
    """When the finding dict has no 'finding_id' key, the emit must fall
    back to a deterministic synthetic id of the form
    ``unknown-<cycle>-<idx>`` rather than emitting an empty finding_id (which
    would fail the Lambda schema's required-non-empty contract)."""
    from dso_ci_review import arbiter_processor

    captured: list[tuple[str, dict]] = []
    ruling = {"finding_index": 7, "ruling": "BLOCK", "rationale": "test"}
    finding: dict = {}  # no finding_id key
    arbiter_processor._emit_arbiter_ruling_telemetry(
        ruling,
        finding,
        finding_idx=7,
        cycle_num=4,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert captured[0][1]["finding_id"] == "unknown-4-7"
    # prior_finding_id falls back to the same synthetic value (no lineage data).
    assert captured[0][1]["prior_finding_id"] == "unknown-4-7"


def test_runner_emit_review_cycle_carries_all_required_fields() -> None:
    """_emit_review_cycle_telemetry must populate every required
    PER_TYPE_FIELD for the review_cycle event, plus correctly aggregate
    counts and pass from the findings list."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []
    findings = [
        {"severity": "critical"},
        {"severity": "important"},
        {"severity": "important"},
        {"severity": "minor"},
        {"severity": "suggestion"},
    ]
    runner._emit_review_cycle_telemetry(
        findings,
        cycle_number=3,
        tier="deep",
        reviewed_sha="abc123",
        usage_input_tokens=10,
        usage_output_tokens=20,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "review_cycle"
    missing = REQUIRED_PER_TYPE_FIELDS["review_cycle"] - set(kwargs.keys())
    assert not missing, f"review_cycle emit dropped fields: {sorted(missing)}"

    # Aggregate counts must be derived correctly from the findings list.
    assert kwargs["finding_count"] == 5
    assert kwargs["critical_count"] == 1
    assert kwargs["important_count"] == 2
    assert kwargs["minor_count"] == 2  # minor + suggestion
    # pass=False because critical_count+important_count > 0
    assert kwargs["pass"] is False
    # resolution_attempts = cycle_number - 1
    assert kwargs["resolution_attempts"] == 2
    # tier enum
    assert kwargs["tier"] in {"light", "standard", "deep"}
    # additive-optional token fields propagated
    assert kwargs["input_tokens"] == 10
    assert kwargs["output_tokens"] == 20


def test_runner_emit_review_cycle_pass_true_when_no_critical_important() -> None:
    """review_cycle pass=True when there are no critical/important findings,
    even if there are minor/suggestion findings."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []
    findings = [{"severity": "minor"}, {"severity": "suggestion"}]
    runner._emit_review_cycle_telemetry(
        findings,
        cycle_number=1,
        tier="standard",
        reviewed_sha="def456",
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert captured[0][1]["pass"] is True
    assert captured[0][1]["resolution_attempts"] == 0
    # additive-optional tokens absent when not passed
    assert "input_tokens" not in captured[0][1]
    assert "output_tokens" not in captured[0][1]


# ---------------------------------------------------------------------------
# Arbiter integration: arbiter_ruling and resolver_outcome emit shapes
# ---------------------------------------------------------------------------


def test_arbiter_emit_ruling_includes_required_fields() -> None:
    """_emit_arbiter_ruling_telemetry must populate every required
    PER_TYPE_FIELD for arbiter_ruling and produce a schema-valid
    arbiter_decision enum value."""
    from dso_ci_review import arbiter_processor

    captured: list[tuple[str, dict]] = []
    ruling = {"finding_index": 0, "ruling": "BLOCK", "rationale": "test rationale"}
    finding = {"finding_id": "f-100"}
    arbiter_processor._emit_arbiter_ruling_telemetry(
        ruling,
        finding,
        finding_idx=0,
        cycle_num=3,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "arbiter_ruling"
    missing = REQUIRED_PER_TYPE_FIELDS["arbiter_ruling"] - set(kwargs.keys())
    assert not missing, f"arbiter_ruling emit dropped fields: {sorted(missing)}"
    # arbiter_decision must land on canonical enum.
    assert kwargs["arbiter_decision"] in {"uphold", "dismiss", "downgrade"}
    # BLOCK → uphold per _RULING_TO_DECISION.
    assert kwargs["arbiter_decision"] == "uphold"


@pytest.mark.parametrize(
    "ruling_type,expected_decision",
    [("BLOCK", "uphold"), ("DEFER", "dismiss"), ("DROP", "dismiss")],
)
def test_arbiter_ruling_type_to_decision_mapping(
    ruling_type, expected_decision
) -> None:
    """The orchestrator ruling_type → arbiter_decision mapping must match
    the canonical _RULING_TO_DECISION constant. A drift here would silently
    emit wrong arbiter_decision values; this is the unit-level regression
    guard."""
    from dso_ci_review import arbiter_processor

    assert arbiter_processor._RULING_TO_DECISION[ruling_type] == expected_decision


def test_arbiter_emit_resolver_outcome_includes_required_fields() -> None:
    """_emit_resolver_outcome_telemetry must populate every required
    PER_TYPE_FIELD for resolver_outcome with a schema-valid resolution_action
    enum value."""
    from dso_ci_review import arbiter_processor

    captured: list[tuple[str, dict]] = []
    finding = {"finding_id": "f-200"}
    arbiter_processor._emit_resolver_outcome_telemetry(
        finding,
        finding_idx=1,
        cycle_num=4,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert len(captured) == 1
    et, kwargs = captured[0]
    assert et == "resolver_outcome"
    missing = REQUIRED_PER_TYPE_FIELDS["resolver_outcome"] - set(kwargs.keys())
    assert not missing, (
        f"resolver_outcome emit dropped fields: {sorted(missing)}"
    )
    assert kwargs["resolution_action"] in {"code_fix", "defense", "escalated"}
    # accepted is a bool per schema.
    assert isinstance(kwargs["accepted"], bool)


def test_arbiter_prior_finding_id_uses_ruling_value_when_present() -> None:
    """When the arbiter recorded a cross-cycle lineage via
    ruling["prior_finding_id"], the emit must use that value rather than the
    current finding's id."""
    from dso_ci_review import arbiter_processor

    captured: list[tuple[str, dict]] = []
    ruling = {
        "finding_index": 0,
        "ruling": "BLOCK",
        "rationale": "test",
        "prior_finding_id": "prev-cycle-finding-id",
    }
    finding = {"finding_id": "f-300"}
    arbiter_processor._emit_arbiter_ruling_telemetry(
        ruling,
        finding,
        finding_idx=0,
        cycle_num=2,
        emit_fn=lambda et, **kw: captured.append((et, kw)),
    )
    assert captured[0][1]["prior_finding_id"] == "prev-cycle-finding-id"
    assert captured[0][1]["finding_id"] == "f-300"
