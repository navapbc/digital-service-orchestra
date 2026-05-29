"""Regression test for bug 7f55 fourth-guard in merge_findings.

PR #448 added producer-side guards to ``runner._run_cluster`` to drop
str-shaped findings before they reach the aggregator. That covers the
cluster path. But the non-cluster path (light/standard tier without
clustering) goes directly through ``async_dispatch_specialists`` →
``merge_findings`` with no guard between them. When a specialist
returns ``{"findings": "<some string>"}`` (a degraded LLM response
shape), the unguarded ``list.extend(str)`` at
``findings.merge_findings`` flattens the string character-by-character
into bogus per-char "findings". Downstream consumers then call
``.get()`` on each char and crash with::

    AttributeError: 'str' object has no attribute 'get'

This test exercises the choke-point guard in ``merge_findings`` directly.
"""

from __future__ import annotations


def test_merge_findings_drops_string_shaped_findings_field() -> None:
    """{"findings": "some string"} must NOT char-flatten into the merged list."""
    from dso_ci_review.findings import merge_findings

    well_formed = {
        "findings": [{"severity": "critical", "description": "real"}],
        "scores": {},
        "summary": "",
    }
    degraded = {"findings": "no issues found", "scores": {}, "summary": ""}

    merged = merge_findings(well_formed, degraded)

    # Only the well-formed finding survives; the degraded string is
    # dropped wholesale rather than char-flattened.
    assert merged["findings"] == [{"severity": "critical", "description": "real"}]
    # No character "findings" leaked in (would be present as single-char strings).
    for f in merged["findings"]:
        assert isinstance(f, dict), f"non-dict finding leaked: {f!r}"


def test_merge_findings_drops_non_dict_items_in_findings_list() -> None:
    """Per-item filter: str/int/None inside a findings list must be dropped."""
    from dso_ci_review.findings import merge_findings

    mixed = {
        "findings": [
            {"severity": "important", "description": "real"},
            "stray string finding",
            42,
            None,
            {"severity": "minor", "description": "another real"},
        ],
        "scores": {},
        "summary": "",
    }

    merged = merge_findings(mixed)

    assert len(merged["findings"]) == 2
    assert all(isinstance(f, dict) for f in merged["findings"])
    assert merged["findings"][0]["description"] == "real"
    assert merged["findings"][1]["description"] == "another real"


def test_merge_findings_drops_numeric_findings_field() -> None:
    """{"findings": 0} or other non-list types must not crash merge_findings."""
    from dso_ci_review.findings import merge_findings

    degraded_zero = {"findings": 0, "scores": {}, "summary": ""}
    degraded_none = {"findings": None, "scores": {}, "summary": ""}
    degraded_dict = {"findings": {"unexpected": "shape"}, "scores": {}, "summary": ""}

    merged = merge_findings(degraded_zero, degraded_none, degraded_dict)

    assert merged["findings"] == []


def test_merge_findings_preserves_scores_when_findings_is_string() -> None:
    """A degraded findings shape must not block scores merging from the same payload."""
    from dso_ci_review.findings import merge_findings

    mixed = {
        "findings": "garbage",  # degraded
        "scores": {"correctness": 3, "verification": 4},
        "summary": "from a partially-degraded reviewer",
    }
    clean = {
        "findings": [{"severity": "important", "description": "real"}],
        "scores": {"correctness": 5, "verification": 2},
        "summary": "from a clean reviewer",
    }

    merged = merge_findings(mixed, clean)

    # Findings: only the clean one.
    assert len(merged["findings"]) == 1
    # Scores: min-merged across both reviewers regardless of degraded findings.
    assert merged["scores"]["correctness"] == 3
    assert merged["scores"]["verification"] == 2
    # Summary: both reviewer summaries preserved.
    assert "partially-degraded reviewer" in merged["summary"]
    assert "clean reviewer" in merged["summary"]


def test_merge_findings_baseline_behavior_unchanged_for_well_formed_input() -> None:
    """The guard must not alter the merged output for legitimately well-formed input."""
    from dso_ci_review.findings import merge_findings

    a = {
        "findings": [{"severity": "critical", "description": "A"}],
        "scores": {"correctness": 2},
        "summary": "a",
    }
    b = {
        "findings": [{"severity": "minor", "description": "B"}],
        "scores": {"correctness": 5, "hygiene": 3},
        "summary": "b",
    }

    merged = merge_findings(a, b)

    assert len(merged["findings"]) == 2
    assert merged["scores"] == {"correctness": 2, "hygiene": 3}
    assert merged["summary"] == "a; b"
