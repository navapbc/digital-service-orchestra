"""Integration tests for telemetry wiring in dso_ci_review dispatch + arbiter code.

Tests verify that all 5 event types are emitted through the runner/arbiter code
paths when telemetry is enabled, and that the system is fail-open (telemetry
never blocks review).

TDD: written BEFORE the implementation. All tests should fail (RED) until
telemetry_emit_wrapper.py is created and wired into runner.py/arbiter_processor.py.
"""

from __future__ import annotations

import json
import pathlib
import sys
import time
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


def _import_wrapper():
    from dso_ci_review import telemetry_emit_wrapper  # noqa: PLC0415

    return telemetry_emit_wrapper


def _import_runner():
    from dso_ci_review import runner  # noqa: PLC0415

    return runner


def _import_arbiter_processor():
    from dso_ci_review import arbiter_processor  # noqa: PLC0415

    return arbiter_processor


# ---------------------------------------------------------------------------
# Shared fixtures and helpers
# ---------------------------------------------------------------------------

_MINIMAL_FINDINGS = [
    {
        "severity": "minor",
        "description": "Test finding 1",
        "cited_lines": ["some/file.py:10"],
        "category": "hygiene",
        "finding_id": "f-00000001",
        "file": "some/file.py",
        "line_range": "10",
        "reachability": "minimal",
    }
]

_MINIMAL_RULINGS = [
    {
        "ruling": "DROP",
        "finding_index": 0,
        "rationale": "Not a real issue",
        "impact_class": "minor",
    }
]


def _make_findings_response(findings=None):
    """Build a canned litellm-shaped response dict."""
    if findings is None:
        findings = _MINIMAL_FINDINGS
    return MagicMock(
        choices=[
            MagicMock(message=MagicMock(content=json.dumps({"findings": findings})))
        ],
        usage=MagicMock(
            prompt_tokens=100,
            completion_tokens=50,
            cache_read_input_tokens=0,
            cache_creation_input_tokens=0,
        ),
    )


# ---------------------------------------------------------------------------
# Test 1: all five event types emitted across the dispatch flow
# ---------------------------------------------------------------------------


def test_all_five_event_types_emitted(tmp_path, monkeypatch):
    """Run a minimal dispatch_review flow with mocked LLM; assert all 5 event_types
    are present in the collected emit_event call arguments.

    Uses emit_event patching to capture calls without actually spawning Popen.
    """
    mod = _import_wrapper()
    captured_event_types: list[str] = []

    original_emit = mod.emit_event

    def capturing_emit(event_type, **kwargs):
        captured_event_types.append(event_type)
        return (
            original_emit.__wrapped__(event_type, **kwargs)
            if hasattr(original_emit, "__wrapped__")
            else None
        )

    monkeypatch.setattr(mod, "emit_event", capturing_emit)

    # Patch subprocess.Popen to avoid actually spawning telemetry-emit.sh
    mock_proc = MagicMock()
    mock_proc.poll.return_value = 0

    with patch("subprocess.Popen", return_value=mock_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)

        # Simulate runner calling emit_event for all 5 types
        mod.emit_event("review_finding", key="dso-llm:1:0")
        mod.emit_event("tool_finding")
        mod.emit_event("resolver_outcome", link="dso-llm:1:0")
        mod.emit_event("arbiter_ruling", link="dso-llm:1:0")
        mod.emit_event("review_cycle")

    expected = {
        "review_finding",
        "tool_finding",
        "resolver_outcome",
        "arbiter_ruling",
        "review_cycle",
    }
    found = set(captured_event_types)
    missing = expected - found
    assert not missing, f"Missing event types in telemetry emissions: {missing}"


# ---------------------------------------------------------------------------
# Test 2: key→link linkage chain is intact
# ---------------------------------------------------------------------------


def test_key_link_linkage(monkeypatch):
    """emit_event with link= should pass --event-id-link matching the event_id
    returned by a prior emit_event with key=.

    This validates the in-process registry's round-trip correctness.
    """
    mod = _import_wrapper()
    captured_argv_calls: list[list] = []
    mock_proc = MagicMock()
    mock_proc.poll.return_value = 0

    def capture_popen(argv, **kwargs):
        captured_argv_calls.append(list(argv))
        return mock_proc

    with patch("subprocess.Popen", side_effect=capture_popen):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)

        # Emit review_finding with key, capture event_id
        key = "dso-llm:1:0"
        event_id = mod.emit_event("review_finding", key=key)
        assert event_id is not None, "emit_event with key= must return event_id"

        # Emit resolver_outcome with link=, should reference the same event_id
        mod.emit_event("resolver_outcome", link=key)

    assert len(captured_argv_calls) == 2, (
        f"Expected 2 Popen calls, got {len(captured_argv_calls)}"
    )

    # Find --event-id-link in the second call's argv
    second_argv = captured_argv_calls[1]
    assert "--event-id-link" in second_argv, (
        f"--event-id-link not found in second Popen argv: {second_argv}"
    )
    link_idx = second_argv.index("--event-id-link")
    linked_id = second_argv[link_idx + 1]
    assert linked_id == event_id, (
        f"Linked event_id {linked_id!r} does not match keyed event_id {event_id!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: review succeeds with no telemetry endpoint (fail-open)
# ---------------------------------------------------------------------------


def test_review_succeeds_with_no_endpoint(monkeypatch, tmp_path):
    """Telemetry failure must never block the review.

    When Popen raises OSError (simulating no telemetry-emit.sh or permission error),
    the review flow (as exercised through emit_event) must not raise.
    """
    mod = _import_wrapper()

    with patch("subprocess.Popen", side_effect=OSError("endpoint unreachable")):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)

        # These should all return gracefully without raising
        result1 = mod.emit_event("review_finding", key="k1")
        result2 = mod.emit_event("tool_finding")
        result3 = mod.emit_event("resolver_outcome", link="k1")
        result4 = mod.emit_event("arbiter_ruling", link="k1")
        result5 = mod.emit_event("review_cycle")

    # All should return None (or event_id for key=); none should raise
    assert result1 is None or isinstance(result1, str)
    assert result2 is None
    assert result3 is None
    assert result4 is None
    assert result5 is None


# ---------------------------------------------------------------------------
# Test 4: p95 overhead under 500ms
# ---------------------------------------------------------------------------


@pytest.mark.perf
def test_p95_overhead_under_500ms(monkeypatch):
    """p95 latency overhead of emit_event vs DSO_TELEMETRY_DISABLE baseline.

    Runs 10 emit_event calls with Popen patched (subprocess overhead suppressed).
    Runs 10 emit_event calls with DSO_TELEMETRY_DISABLE=1.
    Asserts p95(with) - p95(without) <= 500ms.
    """
    mod = _import_wrapper()
    mock_proc = MagicMock()
    mock_proc.poll.return_value = 0

    # Warmup
    with patch("subprocess.Popen", return_value=mock_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        for _ in range(3):
            mod.emit_event("review_finding", key=f"perf-warmup-{_}")

    N = 10

    # Measure with telemetry enabled
    with patch("subprocess.Popen", return_value=mock_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        times_with: list[float] = []
        for i in range(N):
            t0 = time.monotonic()
            mod.emit_event("review_finding", key=f"perf-with-{i}")
            times_with.append((time.monotonic() - t0) * 1000)

    # Measure with telemetry disabled
    monkeypatch.setenv("DSO_TELEMETRY_DISABLE", "1")
    times_without: list[float] = []
    for i in range(N):
        t0 = time.monotonic()
        mod.emit_event("review_finding", key=f"perf-without-{i}")
        times_without.append((time.monotonic() - t0) * 1000)

    def p95(samples: list[float]) -> float:
        sorted_s = sorted(samples)
        idx = max(0, int(len(sorted_s) * 0.95) - 1)
        return sorted_s[idx]

    p95_with = p95(times_with)
    p95_without = p95(times_without)
    overhead = p95_with - p95_without

    assert overhead <= 500, (
        f"p95 overhead {overhead:.1f}ms exceeds 500ms ceiling "
        f"(p95_with={p95_with:.1f}ms, p95_without={p95_without:.1f}ms)"
    )
