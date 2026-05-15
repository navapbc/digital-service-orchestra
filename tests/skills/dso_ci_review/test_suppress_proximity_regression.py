"""Replay regression tests for empirical PR-102 and PR-103 suppression data.

These tests assert the >=60% downgrade design target on synthetic fixtures
derived from the empirical PR-102 and PR-103 review-loop runs (see story
1ef8-79c4 description). The fixture findings use *rephrased* descriptions
relative to the defense records, so the current description-prefix matcher
in runner._suppress_defended_findings will fail to downgrade them — these
tests are expected to fail before T4 (proximity-aware matcher) lands and
to pass after.

A legacy-fallback test (`test_pr102_legacy_defense_fallback`) exercises the
backward-compatible description-prefix path and SHOULD PASS today; it stays
green after T4 to guard against regression of the legacy matcher.
"""

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures"

# Ensure scripts dir is importable so we can pull in runner._suppress_defended_findings.
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from dso_ci_review.runner import _suppress_defended_findings  # noqa: E402


def _load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _pct_downgraded(filtered: list[dict]) -> float:
    if not filtered:
        return 0.0
    downgraded = sum(
        1 for f in filtered if str(f.get("severity", "")).lower() == "suggestion"
    )
    return downgraded / len(filtered)


def test_pr102_cycle2_replay_suppresses_60pct():
    """Replay: PR-102 cycle-1 defenses applied to cycle-2 findings.

    Design target: >=60% of cycle-2 findings should be downgraded to 'suggestion'
    because their cited_lines fall within ±5 of cycle-1 defended lines.

    Current behavior (description-prefix matcher) will downgrade 0% because the
    fixture findings use rephrased descriptions. This test is RED before T4.
    """
    defenses = _load_jsonl(FIXTURE_DIR / "pr-102-cycle-1-defenses.jsonl")
    findings = _load_jsonl(FIXTURE_DIR / "pr-102-cycle-2-findings.jsonl")

    filtered = _suppress_defended_findings(findings, defenses)
    pct = _pct_downgraded(filtered)
    assert pct >= 0.60, (
        f"Expected >=60% of PR-102 cycle-2 findings downgraded; got {pct:.0%} "
        f"({sum(1 for f in filtered if f.get('severity') == 'suggestion')}/{len(filtered)})"
    )


def test_pr103_cycle3_replay_suppresses_60pct():
    """Replay: PR-103 cycle-2 defenses applied to cycle-3 findings.

    Design target: >=60% downgrade. RED before T4 because the matcher uses
    description prefix and the fixture descriptions are rephrased.
    """
    defenses = _load_jsonl(FIXTURE_DIR / "pr-103-cycle-2-defenses.jsonl")
    findings = _load_jsonl(FIXTURE_DIR / "pr-103-cycle-3-findings.jsonl")

    filtered = _suppress_defended_findings(findings, defenses)
    pct = _pct_downgraded(filtered)
    assert pct >= 0.60, (
        f"Expected >=60% of PR-103 cycle-3 findings downgraded; got {pct:.0%} "
        f"({sum(1 for f in filtered if f.get('severity') == 'suggestion')}/{len(filtered)})"
    )


def test_pr102_legacy_defense_fallback():
    """Backward-compat: legacy defenses with matching description prefix still suppress.

    Even when a defense record lacks `cited_lines`, the legacy
    (severity, description[:80]) matcher should still downgrade findings whose
    severity and description prefix match. This guards the fallback path so
    T4's proximity-aware matcher does not break it.
    """
    defenses = [
        {
            "severity": "important",
            "description": "Legacy reviewer flagged race condition in cache eviction path",
            "defense_text": "Pre-existing behavior; deferred to follow-up ticket.",
            "cycle_number": 1,
        }
    ]
    findings = [
        # Matches on (severity, description[:80])
        {
            "finding_id": "f-aaaa",
            "severity": "important",
            "description": "Legacy reviewer flagged race condition in cache eviction path",
            "cited_lines": ["foo.py:10"],
        },
        # Distinct description — should NOT be downgraded
        {
            "finding_id": "f-bbbb",
            "severity": "important",
            "description": "Completely different finding about logging verbosity",
            "cited_lines": ["bar.py:20"],
        },
    ]

    filtered = _suppress_defended_findings(findings, defenses)
    by_id = {f["finding_id"]: f for f in filtered}
    assert by_id["f-aaaa"]["severity"] == "suggestion", (
        "Legacy prefix match should downgrade f-aaaa to 'suggestion'"
    )
    assert by_id["f-bbbb"]["severity"] == "important", (
        "Non-matching finding f-bbbb should retain original severity"
    )
