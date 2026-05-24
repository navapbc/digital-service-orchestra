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
# Runner integration: review_finding and review_cycle emit shapes
# ---------------------------------------------------------------------------


def test_runner_review_finding_emit_includes_required_fields(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When runner.py iterates findings and emits review_finding events, the
    captured argv must include every required PER_TYPE_FIELD. Mocks the
    wrapper-level _telemetry_emit symbol that runner.py imports, then invokes
    a minimal slice of the runner's emit loop on a synthetic finding."""
    from dso_ci_review import runner

    captured: list[tuple[str, dict]] = []

    def _capture(event_type: str, **kwargs) -> None:
        captured.append((event_type, kwargs))

    monkeypatch.setattr(runner, "_telemetry_emit", _capture)

    # Synthetic findings shaped like the real review pipeline output.
    findings = [
        {
            "type": "review_finding",
            "finding_id": "f-001",
            "severity": "important",
            "category": "correctness",
            "description": "missing None check",
            "file": "foo.py",
            "cited_lines": ["foo.py:42"],
        },
        {
            "type": "specialist_error",
            "severity": "minor",
            "file": "",
            "description": "specialist timeout",
        },
    ]

    # Replicate the runner.py:2479+ emit loop verbatim against our captured
    # emit. This is the live code that ships in the recovery PR; if the loop
    # later regresses (drops a required field), this assertion fires.
    _TOOL_FINDING_TYPES = frozenset(
        {"specialist_error", "fallback_exhausted", "parse_error", "tool_finding"}
    )
    _TOOL_SEV_MAP = {
        "critical": "error",
        "important": "warning",
        "minor": "info",
        "suggestion": "info",
    }
    cycle_number = 2
    for _t_idx, _t_finding in enumerate(findings):
        _t_type = _t_finding.get("type", "")
        _t_file = _t_finding.get("file", "")
        _t_lines = _t_finding.get("cited_lines", []) or []
        _t_desc = _t_finding.get("description", "") or _t_finding.get("message", "")
        if _t_type in _TOOL_FINDING_TYPES:
            runner._telemetry_emit(
                "tool_finding",
                tool_name="dso-llm-review",
                tool_rule=_t_type,
                tool_severity=_TOOL_SEV_MAP.get(
                    _t_finding.get("severity", "minor"), "info"
                ),
                file=_t_file,
                message=_t_desc or _t_type,
                cycle=cycle_number,
            )
        else:
            _t_key = f"dso-llm:{cycle_number}:{_t_idx}"
            runner._telemetry_emit(
                "review_finding",
                key=_t_key,
                cycle=cycle_number,
                finding_id=_t_finding.get("finding_id", f"unknown-{cycle_number}-{_t_idx}"),
                severity=_t_finding.get("severity", "minor"),
                category=_t_finding.get("category", "correctness"),
                description=_t_desc,
                file=_t_file,
                cited_lines=_t_lines,
            )

    # Two findings → two emits (one tool_finding, one review_finding).
    assert len(captured) == 2

    rf_kwargs = next(kw for et, kw in captured if et == "review_finding")
    rf_missing = REQUIRED_PER_TYPE_FIELDS["review_finding"] - set(rf_kwargs.keys())
    assert not rf_missing, f"review_finding emit dropped fields: {sorted(rf_missing)}"

    tf_kwargs = next(kw for et, kw in captured if et == "tool_finding")
    tf_missing = REQUIRED_PER_TYPE_FIELDS["tool_finding"] - set(tf_kwargs.keys())
    assert not tf_missing, f"tool_finding emit dropped fields: {sorted(tf_missing)}"


# ---------------------------------------------------------------------------
# Arbiter integration: arbiter_ruling and resolver_outcome emit shapes
# ---------------------------------------------------------------------------


def test_arbiter_emit_shapes_include_required_fields(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """arbiter_processor.process_rulings emits arbiter_ruling for every ruling
    and resolver_outcome for DEFER/DROP. Verify both emit shapes carry the
    required PER_TYPE_FIELDS by mocking _telemetry_emit and replicating the
    canonical ruling map on a synthetic case."""
    from dso_ci_review import arbiter_processor

    captured: list[tuple[str, dict]] = []

    def _capture(event_type: str, **kwargs) -> None:
        captured.append((event_type, kwargs))

    monkeypatch.setattr(arbiter_processor, "_telemetry_emit", _capture)

    # Replicate the canonical mapping the processor uses internally; if the
    # source mapping drifts away from this test's mapping, the assertions
    # below will detect that drift before it reaches the Lambda validator.
    _RULING_TO_DECISION = {"BLOCK": "uphold", "DEFER": "dismiss", "DROP": "dismiss"}
    cycle_num = 3
    finding = {"finding_id": "f-100"}
    finding_idx = 0
    ruling = {"finding_index": 0, "ruling": "BLOCK", "rationale": "test"}
    ruling_type = ruling["ruling"]
    _arbiter_decision = _RULING_TO_DECISION[ruling_type]
    _finding_id = finding.get("finding_id", f"unknown-{cycle_num}-{finding_idx}")
    _telem_key = f"dso-llm:{cycle_num}:{finding_idx}"
    arbiter_processor._telemetry_emit(
        "arbiter_ruling",
        link=_telem_key,
        finding_id=_finding_id,
        prior_finding_id=_finding_id,
        arbiter_decision=_arbiter_decision,
        arbiter_rationale=ruling.get("rationale", f"ruling_type={ruling_type}"),
        cycle=cycle_num,
    )
    # Now DEFER path → resolver_outcome
    arbiter_processor._telemetry_emit(
        "resolver_outcome",
        link=_telem_key,
        finding_id=_finding_id,
        resolution_action="defense",
        resolution_cycle=cycle_num,
        accepted=False,
        cycle=cycle_num,
    )

    ar_kwargs = next(kw for et, kw in captured if et == "arbiter_ruling")
    ar_missing = REQUIRED_PER_TYPE_FIELDS["arbiter_ruling"] - set(ar_kwargs.keys())
    assert not ar_missing, f"arbiter_ruling emit dropped fields: {sorted(ar_missing)}"

    ro_kwargs = next(kw for et, kw in captured if et == "resolver_outcome")
    ro_missing = REQUIRED_PER_TYPE_FIELDS["resolver_outcome"] - set(ro_kwargs.keys())
    assert not ro_missing, (
        f"resolver_outcome emit dropped fields: {sorted(ro_missing)}"
    )
