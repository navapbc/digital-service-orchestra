from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "plugins" / "dso" / "scripts"))

from dogfood_visual_evaluator import (  # noqa: E402
    SeedPR,
    _compute_missed,
    _is_ui_file,
    replay_pr,
    report_dogfood,
)


def test_is_ui_file_recognizes_common_ui_extensions() -> None:
    assert _is_ui_file("src/app.tsx") is True
    assert _is_ui_file("templates/index.jinja2") is True
    assert _is_ui_file("styles/main.css") is True
    assert _is_ui_file("scripts/server.py") is False
    assert _is_ui_file("docs/README.md") is False


def test_compute_missed_severity_floor() -> None:
    """Only findings at severity >= medium are counted."""
    visual = [
        {
            "severity": "medium",
            "dimension": "whitespace_balance",
            "dom_xpath": "//div[1]",
        },
        {"severity": "low", "dimension": "intent_match", "dom_xpath": "//div[2]"},
    ]
    prior: list = []
    missed = _compute_missed(visual, prior)
    assert len(missed) == 1
    assert missed[0]["severity"] == "medium"


def test_compute_missed_excludes_already_in_prior() -> None:
    """Findings already present in prior reviewer output are excluded."""
    visual = [
        {
            "severity": "major",
            "dimension": "alignment_grid_adherence",
            "dom_xpath": "//nav",
        },
    ]
    prior = [
        {"dimension": "alignment_grid_adherence", "dom_xpath": "//nav"},
    ]
    missed = _compute_missed(visual, prior)
    assert len(missed) == 0


def test_replay_pr_with_stub_visual_findings() -> None:
    """Replay returns visual findings from stub and computes missed."""
    stub = {
        "findings": [
            {
                "severity": "major",
                "dimension": "alignment_grid_adherence",
                "dom_xpath": "//nav",
            },
        ]
    }
    result = replay_pr(123, stub_visual_findings=stub)
    assert result["pr_number"] == 123
    assert len(result["missed_findings"]) == 1


def test_report_dogfood_insufficient_sample() -> None:
    """1 seed PR -> insufficient_sample status (need >=3)."""
    seeds = [
        SeedPR(
            number=1, title="t", merged_at="2026-05-25T00:00:00Z", ui_files_changed=2
        )
    ]
    results = [replay_pr(1)]
    report = report_dogfood(seeds, results)
    assert report["status"] == "insufficient_sample"
    assert "Only 1 qualifying PRs" in report["message"]


def test_report_dogfood_ok_with_3_prs_and_missed_findings() -> None:
    """3 seed PRs each with >=1 missed finding -> status=ok, qualifying_prs has all 3."""
    seeds = [
        SeedPR(
            number=i,
            title=f"PR-{i}",
            merged_at="2026-05-25T00:00:00Z",
            ui_files_changed=2,
        )
        for i in [1, 2, 3]
    ]
    stub = {
        "findings": [
            {
                "severity": "major",
                "dimension": "alignment_grid_adherence",
                "dom_xpath": "//div",
            }
        ]
    }
    results = [replay_pr(i, stub_visual_findings=stub) for i in [1, 2, 3]]
    report = report_dogfood(seeds, results)
    assert report["status"] == "ok"
    assert len(report["qualifying_prs"]) == 3


def test_discover_seed_prs_returns_list() -> None:
    """discover_seed_prs is callable and returns a list (may be empty when gh unavailable)."""
    from dogfood_visual_evaluator import discover_seed_prs

    result = discover_seed_prs(merged_since_days=90, min_ui_files=1)
    assert isinstance(result, list)
