from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
AGENT_PATH = REPO_ROOT / "plugins/dso/agents/visual-evaluator.md"


@pytest.fixture
def agent_content() -> str:
    return AGENT_PATH.read_text()


def test_agent_file_exists() -> None:
    assert AGENT_PATH.exists(), "visual-evaluator.md must exist"


def test_25_rubric_anchors(agent_content: str) -> None:
    """Rubric anchor table must have exactly 25 rows (5 dimensions × 5 scores)."""
    lines = agent_content.splitlines()
    table_rows = [
        ln
        for ln in lines
        if ln.strip().startswith("|")
        and "|" in ln
        and not ln.strip().startswith("| Dimension")
        and not ln.strip().startswith("|---|")
        and not ln.strip().startswith("| ID")
        and not ln.strip().startswith("| attribution")
    ]
    # Count rows that look like rubric entries (contain a digit 1-5 and a dimension name)
    dimensions = {
        "whitespace_balance",
        "element_density",
        "visual_hierarchy_legibility",
        "alignment_grid_adherence",
        "intent_match",
    }
    rubric_rows = [
        row
        for row in table_rows
        if any(d in row for d in dimensions) and re.search(r"\|\s*[1-5]\s*\|", row)
    ]
    assert len(rubric_rows) == 25, (
        f"Expected 25 rubric anchor rows (5 dimensions × 5 scores), found {len(rubric_rows)}"
    )


def test_attribution_decision_tree(agent_content: str) -> None:
    """Attribution decision tree must reference all 4 attribution_class values."""
    required_classes = {
        "implementation_drift",
        "design_flaw",
        "mixed",
        "uncertain",
    }
    for cls in required_classes:
        assert cls in agent_content, (
            f"Attribution class '{cls}' not found in decision tree"
        )


def test_few_shot_coverage(agent_content: str) -> None:
    """Few-shot table must have >= 12 examples with >= 3 per attribution_class."""
    classes = ["implementation_drift", "design_flaw", "mixed", "uncertain"]
    counts: dict[str, int] = {c: 0 for c in classes}
    lines = agent_content.splitlines()
    for line in lines:
        if not (line.strip().startswith("|") and "fs-" in line):
            continue
        for cls in classes:
            if cls in line:
                counts[cls] += 1
    total = sum(counts.values())
    assert total >= 12, (
        f"Expected >= 12 few-shot examples, found {total}. Counts: {counts}"
    )
    for cls, count in counts.items():
        assert count >= 3, f"Expected >= 3 examples for '{cls}', found {count}"


def test_mobile_desktop_contrastive_pairs(agent_content: str) -> None:
    """Few-shot examples must include both mobile and desktop viewport references."""
    assert "mobile" in agent_content.lower(), "No mobile viewport examples found"
    assert "desktop" in agent_content.lower(), "No desktop viewport examples found"


def test_params_yaml_referenced(agent_content: str) -> None:
    assert "visual-evaluator-params.yaml" in agent_content


def test_all_sc1_fields_mentioned(agent_content: str) -> None:
    """All SC-1 schema fields must be referenced in the agent file."""
    fields = [
        "bbox_confidence",
        "dom_xpath",
        "dom_xpath_visually_consistent",
        "attribution_class",
        "attribution_confidence",
        "scores",
    ]
    for field in fields:
        assert field in agent_content, f"SC-1 field '{field}' not found in agent file"
