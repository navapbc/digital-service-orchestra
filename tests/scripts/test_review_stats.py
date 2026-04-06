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
