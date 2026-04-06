"""RED tests for review_stats.py aggregation module.

These tests are RED -- they test functionality that does not yet exist.
All test functions must FAIL before review_stats.py is implemented.

The module is expected to expose:
    read_events(path: Path) -> list[dict]
    compute_pass_fail_rates(events: list[dict]) -> dict
    compute_avg_dimension_scores(events: list[dict]) -> dict[str, float]
    compute_finding_severity_distribution(events: list[dict]) -> dict[str, int]
    filter_by_time_window(events: list[dict], days: int) -> list[dict]

Test: python3 -m pytest tests/scripts/test_review_stats.py
All tests must return non-zero until review_stats.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading -- filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "review-stats.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("review_stats", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def review_stats() -> ModuleType:
    """Return the review-stats module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"review-stats.py not found at {SCRIPT_PATH} -- "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_review_event(
    *,
    result: str = "passed",
    tier: str = "standard",
    dimensions: dict[str, float] | None = None,
    findings: list[dict] | None = None,
    timestamp: str | None = None,
) -> dict:
    """Build a review_result event dict."""
    ts = timestamp or datetime.now(tz=timezone.utc).isoformat()
    return {
        "event_type": "review_result",
        "timestamp": ts,
        "pass_fail": result,
        "tier": tier,
        "dimension_scores": dimensions or {},
        "findings": findings or [],
    }


def _write_jsonl(path: Path, events: list[dict | str]) -> None:
    """Write events as JSONL. Accepts dicts (serialized) or raw strings."""
    with path.open("w") as f:
        for event in events:
            if isinstance(event, dict):
                f.write(json.dumps(event) + "\n")
            else:
                f.write(event + "\n")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_read_events_valid_jsonl(review_stats: ModuleType, tmp_path: Path) -> None:
    """read_events reads well-formed JSONL and returns correct event count."""
    events = [
        _make_review_event(result="passed"),
        _make_review_event(result="failed"),
        _make_review_event(result="passed"),
    ]
    jsonl_file = tmp_path / "reviews.jsonl"
    _write_jsonl(jsonl_file, events)

    result = review_stats.read_events(jsonl_file)

    assert isinstance(result, list)
    assert len(result) == 3
    assert result[0]["pass_fail"] == "passed"
    assert result[1]["pass_fail"] == "failed"


def test_read_events_skips_malformed(
    review_stats: ModuleType, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """read_events skips malformed lines and logs a warning.

    Also covers AC amendment: valid JSON missing required fields is skipped.
    """
    valid_event = _make_review_event(result="passed")
    malformed_line = "{this is not valid json"
    missing_fields = json.dumps({"some_key": "no event_type field"})

    jsonl_file = tmp_path / "reviews.jsonl"
    _write_jsonl(jsonl_file, [valid_event, malformed_line, missing_fields])

    with caplog.at_level(logging.WARNING):
        result = review_stats.read_events(jsonl_file)

    assert len(result) == 1
    assert result[0]["pass_fail"] == "passed"
    # At least one warning logged for skipped lines
    assert len(caplog.records) >= 1


def test_compute_pass_fail_rates(review_stats: ModuleType) -> None:
    """3 passed + 1 failed -> pass_rate=75%, fail_rate=25%."""
    events = [
        _make_review_event(result="passed"),
        _make_review_event(result="passed"),
        _make_review_event(result="passed"),
        _make_review_event(result="failed"),
    ]

    rates = review_stats.compute_pass_fail_rates(events)

    assert isinstance(rates, dict)
    assert rates["pass_rate"] == pytest.approx(75.0)
    assert rates["fail_rate"] == pytest.approx(25.0)
    assert rates["total"] == 4


def test_compute_avg_dimension_scores(review_stats: ModuleType) -> None:
    """Known dimension scores produce correct averages."""
    events = [
        _make_review_event(
            dimensions={
                "correctness": 8.0,
                "verification": 6.0,
                "hygiene": 10.0,
                "design": 4.0,
                "maintainability": 7.0,
            }
        ),
        _make_review_event(
            dimensions={
                "correctness": 6.0,
                "verification": 8.0,
                "hygiene": 6.0,
                "design": 8.0,
                "maintainability": 5.0,
            }
        ),
    ]

    avgs = review_stats.compute_avg_dimension_scores(events)

    assert isinstance(avgs, dict)
    assert avgs["correctness"] == pytest.approx(7.0)
    assert avgs["verification"] == pytest.approx(7.0)
    assert avgs["hygiene"] == pytest.approx(8.0)
    assert avgs["design"] == pytest.approx(6.0)
    assert avgs["maintainability"] == pytest.approx(6.0)


def test_compute_finding_severity_distribution(review_stats: ModuleType) -> None:
    """Mixed severities produce correct count per severity level."""
    events = [
        _make_review_event(
            findings=[
                {"severity": "critical", "message": "SQL injection"},
                {"severity": "important", "message": "Missing null check"},
            ]
        ),
        _make_review_event(
            findings=[
                {"severity": "critical", "message": "Auth bypass"},
                {"severity": "minor", "message": "Typo in docstring"},
                {"severity": "important", "message": "Race condition"},
            ]
        ),
    ]

    dist = review_stats.compute_finding_severity_distribution(events)

    assert isinstance(dist, dict)
    assert dist["critical"] == 2
    assert dist["important"] == 2
    assert dist["minor"] == 1


def _make_review_event_with_heuristic(
    *,
    test_gate_status: str = "passed",
    dimension: str = "correctness",
    severity: str = "critical",
    resolution: str = "code-change",
    result: str = "passed",
    tier: str = "standard",
    timestamp: str | None = None,
    overlay_security: bool = False,
    overlay_performance: bool = False,
    escalated: bool = False,
) -> dict:
    """Build a review_result event with fields needed for compound heuristic."""
    ts = timestamp or datetime.now(tz=timezone.utc).isoformat()
    event: dict = {
        "event_type": "review_result",
        "timestamp": ts,
        "pass_fail": result,
        "tier": tier,
        "test_gate_status": test_gate_status,
        "dimension_scores": {},
        "findings": [
            {
                "severity": severity,
                "dimension": dimension,
                "resolution": resolution,
                "message": "test finding",
            }
        ],
    }
    if overlay_security:
        event["overlays"] = event.get("overlays", []) + ["security"]
    if overlay_performance:
        event["overlays"] = event.get("overlays", []) + ["performance"]
    if escalated:
        event["escalated"] = True
    return event


# ---------------------------------------------------------------------------
# Compound heuristic tests
# ---------------------------------------------------------------------------


def test_compound_heuristic_all_criteria_met(review_stats: ModuleType) -> None:
    """Event meeting all 4 criteria: test_gate_status=passed, correctness
    dimension, critical severity, code-change resolution -> counted."""
    events = [
        _make_review_event_with_heuristic(
            test_gate_status="passed",
            dimension="correctness",
            severity="critical",
            resolution="code-change",
        ),
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["review_caught_bugs"] == 1


def test_compound_heuristic_failing_tests(review_stats: ModuleType) -> None:
    """Same event but test_gate_status=failed -> NOT counted."""
    events = [
        _make_review_event_with_heuristic(
            test_gate_status="failed",
            dimension="correctness",
            severity="critical",
            resolution="code-change",
        ),
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["review_caught_bugs"] == 0


def test_compound_heuristic_defense_resolution(review_stats: ModuleType) -> None:
    """Resolution is defense (not code-change) -> NOT counted."""
    events = [
        _make_review_event_with_heuristic(
            test_gate_status="passed",
            dimension="correctness",
            severity="critical",
            resolution="defense",
        ),
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["review_caught_bugs"] == 0


def test_compound_heuristic_hygiene_dimension(review_stats: ModuleType) -> None:
    """Dimension is hygiene -> NOT counted."""
    events = [
        _make_review_event_with_heuristic(
            test_gate_status="passed",
            dimension="hygiene",
            severity="critical",
            resolution="code-change",
        ),
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["review_caught_bugs"] == 0


def test_tier_usage_distribution(review_stats: ModuleType) -> None:
    """Events with mixed tiers produce correct tier counts."""
    events = [
        _make_review_event_with_heuristic(tier="light"),
        _make_review_event_with_heuristic(tier="light"),
        _make_review_event_with_heuristic(tier="standard"),
        _make_review_event_with_heuristic(tier="deep"),
        _make_review_event_with_heuristic(tier="deep"),
        _make_review_event_with_heuristic(tier="deep"),
    ]
    metrics = review_stats.compute_metrics(events)
    tier_dist = metrics["tier_distribution"]
    assert tier_dist["light"] == 2
    assert tier_dist["standard"] == 1
    assert tier_dist["deep"] == 3


def test_overlay_trigger_counts(review_stats: ModuleType) -> None:
    """Events with overlay data produce correct overlay counts."""
    events = [
        _make_review_event_with_heuristic(overlay_security=True),
        _make_review_event_with_heuristic(
            overlay_security=True, overlay_performance=True
        ),
        _make_review_event_with_heuristic(overlay_performance=True),
        _make_review_event_with_heuristic(),  # no overlays
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["overlay_counts"]["security"] == 2
    assert metrics["overlay_counts"]["performance"] == 2


def test_escalation_frequency(review_stats: ModuleType) -> None:
    """Events with escalated=True are counted."""
    events = [
        _make_review_event_with_heuristic(escalated=True),
        _make_review_event_with_heuristic(escalated=True),
        _make_review_event_with_heuristic(escalated=False),
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["escalation_count"] == 2


def test_time_window_filtering(review_stats: ModuleType) -> None:
    """Events spanning 60 days, 30-day window -> only recent 30 days included."""
    now = datetime.now(tz=timezone.utc)
    old_ts = (now - timedelta(days=45)).isoformat()
    recent_ts_1 = (now - timedelta(days=10)).isoformat()
    recent_ts_2 = (now - timedelta(days=5)).isoformat()

    events = [
        _make_review_event(result="passed", timestamp=old_ts),
        _make_review_event(result="failed", timestamp=recent_ts_1),
        _make_review_event(result="passed", timestamp=recent_ts_2),
    ]

    filtered = review_stats.filter_by_time_window(events, days=30)

    assert isinstance(filtered, list)
    assert len(filtered) == 2
    # Only the recent events survive
    assert all(
        datetime.fromisoformat(e["timestamp"]) > now - timedelta(days=30)
        for e in filtered
    )


def test_commit_avg_duration(review_stats: ModuleType) -> None:
    """Commit workflow events with duration_ms produce correct avg_duration."""
    now = datetime.now(tz=timezone.utc)
    events = [
        {
            "event_type": "commit_workflow",
            "timestamp": now.isoformat(),
            "phase": "end",
            "outcome": "committed",
            "duration_ms": 1000,
        },
        {
            "event_type": "commit_workflow",
            "timestamp": now.isoformat(),
            "phase": "end",
            "outcome": "committed",
            "duration_ms": 2000,
        },
        {
            "event_type": "commit_workflow",
            "timestamp": now.isoformat(),
            "phase": "end",
            "outcome": "committed",
            "duration_ms": 3000,
        },
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["commit_stats"]["avg_duration_ms"] == pytest.approx(2000.0)


def test_commit_avg_duration_excludes_blocked(review_stats: ModuleType) -> None:
    """Only committed events contribute to avg_duration_ms."""
    now = datetime.now(tz=timezone.utc)
    events = [
        {
            "event_type": "commit_workflow",
            "timestamp": now.isoformat(),
            "phase": "end",
            "outcome": "committed",
            "duration_ms": 1000,
        },
        {
            "event_type": "commit_workflow",
            "timestamp": now.isoformat(),
            "phase": "end",
            "outcome": "blocked",
            "duration_ms": 9000,
        },
    ]
    metrics = review_stats.compute_metrics(events)
    assert metrics["commit_stats"]["avg_duration_ms"] == pytest.approx(1000.0)


def test_commit_avg_duration_no_events(review_stats: ModuleType) -> None:
    """No commit events -> avg_duration_ms is 0."""
    metrics = review_stats.compute_metrics([])
    assert metrics["commit_stats"]["avg_duration_ms"] == 0.0
