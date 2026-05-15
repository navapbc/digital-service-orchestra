"""RED tests for proximity-aware _suppress_defended_findings (runner.py).

These tests FAIL against the current codebase because _suppress_defended_findings
currently keys on (severity, description[:80]) and ignores cited_lines entirely.
T4 will rewrite the function to use compute_proximity_overlap on cited_lines
and fall back to the description-prefix path only when cited_lines are absent.

RED marker: plugins/dso/scripts/dso_ci_review/runner.py [test_proximity_cited_lines_suppress_overlap]
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[3] / "plugins" / "dso" / "scripts"))

from dso_ci_review.runner import _suppress_defended_findings  # noqa: E402


def _finding(
    severity: str, description: str, cited_lines: list[str] | None = None
) -> dict:
    f: dict = {"severity": severity, "description": description}
    if cited_lines is not None:
        f["cited_lines"] = cited_lines
    return f


def _defense(
    severity: str, description: str, cited_lines: list[str] | None = None
) -> dict:
    d: dict = {"severity": severity, "description": description}
    if cited_lines is not None:
        d["cited_lines"] = cited_lines
    return d


def test_proximity_cited_lines_suppress_overlap() -> None:
    """Defense cited_lines=['runner.py:42'], finding cited_lines=['runner.py:43']
    (within ±5 but description differs) → finding severity downgraded to 'suggestion'.

    This FAILS against current code: description prefix differs, so current
    keyed-match misses; only proximity matching catches it.
    """
    findings = [
        _finding(
            "critical",
            "Different wording than defense but same region",
            cited_lines=["runner.py:43"],
        )
    ]
    defenses = [
        _defense(
            "critical",
            "Original defended finding text",
            cited_lines=["runner.py:42"],
        )
    ]

    result = _suppress_defended_findings(findings, defenses)

    assert result[0]["severity"] == "suggestion"
    assert "_suppressed_reason" in result[0]


def test_proximity_cited_lines_no_suppress_outside_window() -> None:
    """Defense cited_lines=['runner.py:42'], finding cited_lines=['runner.py:55']
    (diff=13, outside ±5 window) → severity unchanged.
    """
    findings = [
        _finding(
            "critical",
            "Different wording than defense and far away",
            cited_lines=["runner.py:55"],
        )
    ]
    defenses = [
        _defense(
            "critical",
            "Original defended finding text",
            cited_lines=["runner.py:42"],
        )
    ]

    result = _suppress_defended_findings(findings, defenses)

    assert result[0]["severity"] == "critical"
    assert "_suppressed_reason" not in result[0]


def test_legacy_fallback_description_prefix_when_no_cited_lines() -> None:
    """Defense has NO cited_lines field, description matches finding → falls
    back to description[:80] suppression (backward compat). Result must have
    severity='suggestion' AND '_suppressed_reason' set.
    """
    desc = "SQL injection vulnerability in user lookup query path"
    findings = [_finding("critical", desc)]  # no cited_lines
    defenses = [_defense("critical", desc)]  # no cited_lines

    result = _suppress_defended_findings(findings, defenses)

    assert result[0]["severity"] == "suggestion"
    assert "_suppressed_reason" in result[0]


def test_different_files_no_suppress() -> None:
    """Defense cited_lines=['foo.py:10'], finding cited_lines=['bar.py:10']
    — different files with same line number → no suppression.
    """
    findings = [_finding("critical", "Some finding", cited_lines=["bar.py:10"])]
    defenses = [_defense("critical", "Some finding", cited_lines=["foo.py:10"])]

    result = _suppress_defended_findings(findings, defenses)

    # Different files → proximity miss. Description matches, but proximity-aware
    # logic should prefer cited_lines when present and not fall back to desc.
    assert result[0]["severity"] == "critical"
    assert "_suppressed_reason" not in result[0]


def test_exact_line_match_suppresses() -> None:
    """Defense cited_lines=['runner.py:100'], finding cited_lines=['runner.py:100']
    — exact line match → suppressed.
    """
    findings = [
        _finding(
            "important",
            "A different description entirely",
            cited_lines=["runner.py:100"],
        )
    ]
    defenses = [
        _defense(
            "important",
            "Original defense description",
            cited_lines=["runner.py:100"],
        )
    ]

    result = _suppress_defended_findings(findings, defenses)

    assert result[0]["severity"] == "suggestion"
    assert "_suppressed_reason" in result[0]


def test_3part_cited_lines_normalization() -> None:
    """Defense stored with 3-part format 'runner.py:42:some content here', finding
    with 2-part 'runner.py:43' → proximity matching still works (T4 must normalize
    3-part to 2-part before calling _parse_cited_line via compute_proximity_overlap).
    """
    findings = [
        _finding(
            "critical",
            "Different wording",
            cited_lines=["runner.py:44"],
        )
    ]
    defenses = [
        _defense(
            "critical",
            "Original defense text",
            cited_lines=["runner.py:42:    def some_function():"],
        )
    ]

    result = _suppress_defended_findings(findings, defenses)

    assert result[0]["severity"] == "suggestion"
    assert "_suppressed_reason" in result[0]
