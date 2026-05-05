"""RED tests for normalize_findings and merge_findings (findings.py).

These tests FAIL until the implementation task adds normalize_findings and
merge_findings to dso_ci_review.findings.

RED marker: tests/skills/dso_ci_review/test_findings.py [test_normalize_valid_json]
"""

from __future__ import annotations


# Both functions do not exist yet — importing them will raise ImportError
# until the implementation task is complete.
from dso_ci_review.findings import merge_findings, normalize_findings  # noqa: F401


class TestNormalizeValidJson:
    """normalize_findings returns a dict with a 'findings' key for valid JSON input."""

    def test_normalize_valid_json(self) -> None:
        """Given: a raw JSON string with findings and scores keys
        When: normalize_findings is called
        Then: returns a dict containing a 'findings' key
        """
        result = normalize_findings('{"findings":[],"scores":{}}')
        assert "findings" in result, (
            f"Expected result to have 'findings' key, got keys: {list(result.keys())!r}"
        )

    def test_normalize_valid_json_findings_is_list(self) -> None:
        """Given: a raw JSON string with a findings array
        When: normalize_findings is called
        Then: the 'findings' value is a list
        """
        result = normalize_findings('{"findings":[],"scores":{}}')
        assert isinstance(result["findings"], list), (
            f"Expected result['findings'] to be a list, got {type(result['findings'])!r}"
        )


class TestNormalizeMarkdownFence:
    """normalize_findings extracts JSON from markdown-fenced code blocks."""

    def test_normalize_markdown_fence(self) -> None:
        """Given: a markdown-fenced JSON string
        When: normalize_findings is called
        Then: the JSON is extracted and returned as a dict with 'findings' key
        """
        fenced = '```json\n{"findings":[]}\n```'
        result = normalize_findings(fenced)
        assert "findings" in result, (
            f"Expected 'findings' key after stripping markdown fence, "
            f"got keys: {list(result.keys())!r}"
        )

    def test_normalize_markdown_fence_with_scores(self) -> None:
        """Given: a markdown-fenced JSON string with scores
        When: normalize_findings is called
        Then: the full JSON is extracted (both findings and scores keys present)
        """
        fenced = '```json\n{"findings":[],"scores":{"correctness":5}}\n```'
        result = normalize_findings(fenced)
        assert "findings" in result, (
            f"Expected 'findings' key after stripping markdown fence, "
            f"got keys: {list(result.keys())!r}"
        )
        assert "scores" in result, (
            f"Expected 'scores' key after stripping markdown fence, "
            f"got keys: {list(result.keys())!r}"
        )


class TestNormalizeInvalidReturnsError:
    """normalize_findings returns a dict with a parse_error entry for unparseable input."""

    def test_normalize_invalid_returns_error(self) -> None:
        """Given: a string that is not valid JSON
        When: normalize_findings is called
        Then: returns a dict whose 'findings' list contains an entry with type 'parse_error'
        """
        result = normalize_findings("not json at all")
        assert "findings" in result, (
            f"Expected 'findings' key in error result, got keys: {list(result.keys())!r}"
        )
        types = [f.get("type") for f in result["findings"]]
        assert "parse_error" in types, (
            f"Expected a finding with type 'parse_error', got types: {types!r}"
        )

    def test_normalize_empty_string_returns_error(self) -> None:
        """Given: an empty string
        When: normalize_findings is called
        Then: returns a dict whose 'findings' list contains a parse_error entry
        """
        result = normalize_findings("")
        assert "findings" in result, (
            f"Expected 'findings' key in error result for empty input, "
            f"got keys: {list(result.keys())!r}"
        )
        types = [f.get("type") for f in result["findings"]]
        assert "parse_error" in types, (
            f"Expected a finding with type 'parse_error' for empty input, "
            f"got types: {types!r}"
        )


class TestMergeCombinesFindings:
    """merge_findings combines findings arrays from all input dicts."""

    def test_merge_combines_findings(self) -> None:
        """Given: two dicts each with one finding
        When: merge_findings is called
        Then: both findings appear in the merged result
        """
        f1 = {
            "severity": "minor",
            "description": "Finding one",
            "cited_lines": ["foo.py:1"],
        }
        f2 = {
            "severity": "important",
            "description": "Finding two",
            "cited_lines": ["bar.py:2"],
        }
        result = merge_findings({"findings": [f1]}, {"findings": [f2]})
        assert "findings" in result, (
            f"Expected 'findings' key in merged result, got keys: {list(result.keys())!r}"
        )
        merged = result["findings"]
        assert len(merged) == 2, (
            f"Expected 2 findings after merge, got {len(merged)}: {merged!r}"
        )

    def test_merge_single_dict_returns_findings_unchanged(self) -> None:
        """Given: a single dict with one finding
        When: merge_findings is called with that single dict
        Then: the merged result contains exactly that one finding
        """
        f1 = {
            "severity": "minor",
            "description": "Solo finding",
            "cited_lines": ["x.py:10"],
        }
        result = merge_findings({"findings": [f1]})
        assert len(result["findings"]) == 1, (
            f"Expected 1 finding for single-dict merge, got {len(result['findings'])}"
        )


class TestMergeTakesMinScores:
    """merge_findings applies conservative (min) merge across score dimensions."""

    def test_merge_takes_min_scores(self) -> None:
        """Given: two dicts with differing correctness scores (3 and 5)
        When: merge_findings is called
        Then: the merged score for 'correctness' is 3 (the minimum)
        """
        result = merge_findings(
            {"scores": {"correctness": 3}},
            {"scores": {"correctness": 5}},
        )
        assert "scores" in result, (
            f"Expected 'scores' key in merged result, got keys: {list(result.keys())!r}"
        )
        assert result["scores"]["correctness"] == 3, (
            f"Expected conservative (min) score of 3, got {result['scores']['correctness']!r}"
        )

    def test_merge_takes_min_across_all_dimensions(self) -> None:
        """Given: two dicts with multiple score dimensions, each varying
        When: merge_findings is called
        Then: the min is applied independently per dimension
        """
        result = merge_findings(
            {"scores": {"correctness": 4, "maintainability": 2}},
            {"scores": {"correctness": 2, "maintainability": 5}},
        )
        assert result["scores"]["correctness"] == 2, (
            f"Expected min correctness=2, got {result['scores'].get('correctness')!r}"
        )
        assert result["scores"]["maintainability"] == 2, (
            f"Expected min maintainability=2, got {result['scores'].get('maintainability')!r}"
        )
