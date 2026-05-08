"""RED tests for 4 new metric functions in review-stats.py.

These tests verify functions that do NOT yet exist in review-stats.py:
  - compute_p90_cycle_count
  - compute_phantom_escalation_rate
  - compute_prior_region_resustain_skew
  - compute_call2_finding_drop_rate

All tests are expected to FAIL (AttributeError) until the functions are
implemented.  Ticket: 1c6e-4741-e07f-4030.
"""

import importlib
import importlib.util
from pathlib import Path

# ---------------------------------------------------------------------------
# Import the module under test
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
_REVIEW_STATS_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "review-stats.py"

# Load review-stats.py as a module (its filename has a hyphen so we use
# importlib.util rather than a plain import statement).

_spec = importlib.util.spec_from_file_location("review_stats", _REVIEW_STATS_PATH)
_review_stats = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(_review_stats)  # type: ignore[union-attr]


# ---------------------------------------------------------------------------
# Helper: build a minimal review_result event
# ---------------------------------------------------------------------------


def _review_event(**kwargs) -> dict:
    """Return a minimal review_result event dict, overrideable via kwargs."""
    base = {"event_type": "review_result"}
    base.update(kwargs)
    return base


# ---------------------------------------------------------------------------
# test_p90_cycle_count
# ---------------------------------------------------------------------------


def test_p90_cycle_count_returns_90th_percentile():
    """compute_p90_cycle_count returns the 90th-percentile of cycle_count values.

    Given 10 review sessions with cycle_count values [1,1,1,1,1,1,1,1,2,5],
    the 90th percentile (numpy-style linear interpolation) falls between 4.0
    and 5.0 — we assert the inclusive range so the test is implementation-
    agnostic w.r.t. exact interpolation method.
    """
    cycle_counts = [1, 1, 1, 1, 1, 1, 1, 1, 2, 5]
    events = [_review_event(cycle_count=c) for c in cycle_counts]

    result = _review_stats.compute_p90_cycle_count(events)

    assert 4.0 <= result <= 5.0, (
        f"Expected 90th-percentile between 4.0 and 5.0, got {result}"
    )


# ---------------------------------------------------------------------------
# test_phantom_escalation_rate
# ---------------------------------------------------------------------------


def test_phantom_escalation_rate_returns_fraction_of_phantom_escalations():
    """compute_phantom_escalation_rate returns fraction of escalations that
    were phantom (finding did not recur in the next cycle).

    Given 4 escalated events where 1 has phantom_escalation=True, the
    function should return 0.25.
    """
    events = [
        _review_event(escalated=True, phantom_escalation=False),
        _review_event(escalated=True, phantom_escalation=False),
        _review_event(escalated=True, phantom_escalation=False),
        _review_event(escalated=True, phantom_escalation=True),
        # Non-escalated events should be ignored
        _review_event(escalated=False, phantom_escalation=False),
    ]

    result = _review_stats.compute_phantom_escalation_rate(events)

    assert result == 0.25, f"Expected phantom escalation rate 0.25 (1/4), got {result}"


# ---------------------------------------------------------------------------
# test_prior_region_resustain_skew
# ---------------------------------------------------------------------------


def test_prior_region_resustain_skew_returns_ratio():
    """compute_prior_region_resustain_skew returns ratio of
    resustain-in-prior-region to resustain-outside-prior-region.

    Given 6 resustain events — 4 with in_prior_region=True and 2 with
    in_prior_region=False — the function should return 2.0 (4/2).
    """
    events = [
        _review_event(event_type="resustain", in_prior_region=True),
        _review_event(event_type="resustain", in_prior_region=True),
        _review_event(event_type="resustain", in_prior_region=True),
        _review_event(event_type="resustain", in_prior_region=True),
        _review_event(event_type="resustain", in_prior_region=False),
        _review_event(event_type="resustain", in_prior_region=False),
        # Non-resustain events should be ignored
        _review_event(event_type="review_result"),
    ]

    result = _review_stats.compute_prior_region_resustain_skew(events)

    assert result == 2.0, (
        f"Expected prior-region resustain skew 2.0 (4/2), got {result}"
    )


# ---------------------------------------------------------------------------
# test_call2_finding_drop_rate
# ---------------------------------------------------------------------------


def test_call2_finding_drop_rate_returns_fraction_of_dropped_findings():
    """compute_call2_finding_drop_rate returns fraction of Call 1 findings
    absent in Call 2 output.

    Given a review session with 10 Call-1 findings and 8 Call-2 findings
    (2 dropped), the function should return 0.2 (2/10).
    """
    events = [
        _review_event(
            call1_finding_count=10,
            call2_finding_count=8,
        ),
    ]

    result = _review_stats.compute_call2_finding_drop_rate(events)

    assert result == 0.2, f"Expected call-2 finding drop rate 0.2 (2/10), got {result}"
