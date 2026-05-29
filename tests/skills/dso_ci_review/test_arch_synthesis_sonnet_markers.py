"""Regression test for the dispatch_arch_synthesis input contract.

The `dso:code-reviewer-deep-arch` agent's Sonnet Findings Guard (see
`plugins/dso/agents/code-reviewer-deep-arch.md`) requires the dispatch
prompt to contain three explicit specialist-findings markers:

  === SONNET-A FINDINGS (correctness) ===
  === SONNET-B FINDINGS (verification) ===
  === SONNET-C FINDINGS (hygiene/design) ===

If any marker is missing, the agent refuses to proceed and returns a
prose refusal. That refusal then fails `_parse_response`'s JSON parse
and surfaces as a ValueError in CI (observed on PR #448 cycle 1).

This test verifies that the runner-side helper that builds the
arch-synthesis input string emits all three markers, each followed by a
JSON array of findings grouped by category.
"""

from __future__ import annotations

import json

import pytest


@pytest.fixture
def merged_with_all_three_categories() -> dict:
    return {
        "findings": [
            {"severity": "critical", "category": "correctness", "description": "C1"},
            {"severity": "important", "category": "verification", "description": "V1"},
            {"severity": "minor", "category": "hygiene", "description": "H1"},
            {"severity": "minor", "category": "design", "description": "D1"},
        ],
        "summary": "irrelevant",
    }


def test_format_merged_for_arch_contains_all_three_markers(
    merged_with_all_three_categories: dict,
) -> None:
    from dso_ci_review.runner import _format_merged_for_arch

    formatted = _format_merged_for_arch(merged_with_all_three_categories)

    assert "=== SONNET-A FINDINGS (correctness) ===" in formatted
    assert "=== SONNET-B FINDINGS (verification) ===" in formatted
    assert "=== SONNET-C FINDINGS (hygiene/design) ===" in formatted


def test_format_merged_for_arch_partitions_findings_by_category(
    merged_with_all_three_categories: dict,
) -> None:
    from dso_ci_review.runner import _format_merged_for_arch

    formatted = _format_merged_for_arch(merged_with_all_three_categories)

    a_idx = formatted.index("=== SONNET-A FINDINGS (correctness) ===")
    b_idx = formatted.index("=== SONNET-B FINDINGS (verification) ===")
    c_idx = formatted.index("=== SONNET-C FINDINGS (hygiene/design) ===")
    assert a_idx < b_idx < c_idx

    section_a = formatted[a_idx:b_idx]
    section_b = formatted[b_idx:c_idx]
    section_c = formatted[c_idx:]

    assert '"description": "C1"' in section_a
    assert '"description": "V1"' in section_b
    # hygiene and design both belong in SONNET-C per agent contract.
    assert '"description": "H1"' in section_c
    assert '"description": "D1"' in section_c


def test_format_merged_for_arch_emits_empty_arrays_for_missing_categories() -> None:
    """All three markers MUST be present even when a category has no findings.

    The agent's Sonnet Findings Guard checks for the marker strings, not
    for findings content — a missing marker triggers refusal even if the
    associated category genuinely had nothing to report.
    """
    from dso_ci_review.runner import _format_merged_for_arch

    formatted = _format_merged_for_arch(
        {"findings": [{"severity": "critical", "category": "correctness", "description": "C1"}]}
    )

    assert "=== SONNET-A FINDINGS (correctness) ===" in formatted
    assert "=== SONNET-B FINDINGS (verification) ===" in formatted
    assert "=== SONNET-C FINDINGS (hygiene/design) ===" in formatted
    # Missing categories present an empty JSON array.
    b_idx = formatted.index("=== SONNET-B FINDINGS (verification) ===")
    c_idx = formatted.index("=== SONNET-C FINDINGS (hygiene/design) ===")
    assert "[]" in formatted[b_idx:c_idx]


def test_format_merged_for_arch_defaults_unknown_category_to_correctness() -> None:
    """A finding with a missing/None/unrecognized category lands in SONNET-A.

    Matches the established default in _normalise_review_category().
    """
    from dso_ci_review.runner import _format_merged_for_arch

    formatted = _format_merged_for_arch(
        {
            "findings": [
                {"severity": "critical", "description": "no-category"},
                {"severity": "critical", "category": "unknown-junk", "description": "junk-cat"},
            ]
        }
    )

    a_idx = formatted.index("=== SONNET-A FINDINGS (correctness) ===")
    b_idx = formatted.index("=== SONNET-B FINDINGS (verification) ===")
    section_a = formatted[a_idx:b_idx]
    assert '"description": "no-category"' in section_a
    assert '"description": "junk-cat"' in section_a


def test_format_merged_for_arch_handles_empty_findings() -> None:
    from dso_ci_review.runner import _format_merged_for_arch

    formatted = _format_merged_for_arch({"findings": []})

    assert "=== SONNET-A FINDINGS (correctness) ===" in formatted
    assert "=== SONNET-B FINDINGS (verification) ===" in formatted
    assert "=== SONNET-C FINDINGS (hygiene/design) ===" in formatted
    # All three sections show an empty JSON array.
    assert formatted.count("[]") >= 3


def test_format_merged_for_arch_per_section_payload_is_valid_json_array() -> None:
    """Each section's payload between markers must parse as a JSON array.

    Guards against the synthesizer rejecting the input due to malformed
    JSON delimiters even when the markers themselves are correct.
    """
    from dso_ci_review.runner import _format_merged_for_arch

    merged = {
        "findings": [
            {"severity": "critical", "category": "correctness", "description": "C1"},
            {"severity": "important", "category": "verification", "description": "V1"},
        ]
    }
    formatted = _format_merged_for_arch(merged)

    def _extract_section(label: str, next_label: str | None) -> str:
        start = formatted.index(label) + len(label)
        if next_label is None:
            payload = formatted[start:]
        else:
            payload = formatted[start : formatted.index(next_label)]
        return payload.strip()

    a_payload = _extract_section(
        "=== SONNET-A FINDINGS (correctness) ===",
        "=== SONNET-B FINDINGS (verification) ===",
    )
    b_payload = _extract_section(
        "=== SONNET-B FINDINGS (verification) ===",
        "=== SONNET-C FINDINGS (hygiene/design) ===",
    )
    c_payload = _extract_section("=== SONNET-C FINDINGS (hygiene/design) ===", None)

    assert isinstance(json.loads(a_payload), list)
    assert isinstance(json.loads(b_payload), list)
    assert isinstance(json.loads(c_payload), list)
