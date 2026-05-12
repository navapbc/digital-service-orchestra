"""RED tests for deduplicate_region_findings() in dso_ci_review/findings.py.

This function does NOT exist yet — all tests must FAIL RED (ImportError or AttributeError).

RED marker: tests/skills/dso_ci_review/test_region_dedup.py [test_max_severity_reconciliation_with_dual_rationale]
"""

from __future__ import annotations

# deduplicate_region_findings does not exist yet — importing will raise ImportError
# until the implementation task adds it to dso_ci_review.findings.
from dso_ci_review.findings import deduplicate_region_findings  # noqa: F401


def _make_finding(
    *,
    severity: str,
    cited_lines: list[str],
    description: str,
    rationale: str = "",
    file_path: str = "src/auth/login.py",
    dimension: str = "correctness",
) -> dict:
    """Build a minimal finding dict matching the reviewer-findings.json schema."""
    return {
        "severity": severity,
        "cited_lines": cited_lines,
        "description": description,
        "rationale": rationale,
        "file_path": file_path,
        "dimension": dimension,
    }


class TestMaxSeverityReconciliationWithDualRationale:
    """When two findings overlap by line range, the critical severity wins and rationale is merged."""

    def test_max_severity_reconciliation_with_dual_rationale(self) -> None:
        """Given: two findings with overlapping line ranges [10,20] and [15,25],
        same file, same dimension, different severities (critical vs important)
        When: deduplicate_region_findings([f_a, f_b]) is called
        Then: returns one finding with severity=critical (MAX)
        AND merged_rationale = {"primary": <critical_rationale>, "secondary": <important_rationale>}
        """
        f_critical = _make_finding(
            severity="critical",
            cited_lines=["src/auth/login.py:10-20"],
            description="Unsafe deserialization allows arbitrary code execution",
            rationale="Attacker controls input at line 15; no sanitization applied.",
        )
        f_important = _make_finding(
            severity="important",
            cited_lines=["src/auth/login.py:15-25"],
            description="Missing input validation before deserialization call",
            rationale="Input validation should precede deserialization at line 17.",
        )

        results = deduplicate_region_findings([f_critical, f_important])

        assert len(results) == 1, (
            f"Expected 1 deduplicated finding, got {len(results)}: {results!r}"
        )
        merged = results[0]
        assert merged["severity"] == "critical", (
            f"Expected severity='critical' (MAX), got {merged['severity']!r}"
        )
        assert "merged_rationale" in merged, (
            f"Expected 'merged_rationale' key in merged finding, got keys: {list(merged.keys())!r}"
        )
        mr = merged["merged_rationale"]
        assert isinstance(mr, dict), (
            f"Expected merged_rationale to be a dict, got {type(mr)!r}"
        )
        assert "primary" in mr and "secondary" in mr, (
            f"Expected merged_rationale to have 'primary' and 'secondary' keys, got {list(mr.keys())!r}"
        )
        assert mr["primary"] == f_critical["rationale"], (
            f"Expected primary rationale from critical finding, got {mr['primary']!r}"
        )
        assert mr["secondary"] == f_important["rationale"], (
            f"Expected secondary rationale from important finding, got {mr['secondary']!r}"
        )


class TestEqualSeverityMergeNoMergedRationaleDuplication:
    """When two overlapping findings share the same severity, no merged_rationale is added."""

    def test_equal_severity_merge_no_merged_rationale_duplication(self) -> None:
        """Given: two findings with same severity, overlapping line range
        When: deduplicate_region_findings is called
        Then: one finding is returned, merged_rationale is absent
        """
        f_a = _make_finding(
            severity="important",
            cited_lines=["src/auth/login.py:5-15"],
            description="No rate limiting on login endpoint",
            rationale="Login endpoint allows unlimited attempts; add rate-limit middleware.",
        )
        f_b = _make_finding(
            severity="important",
            cited_lines=["src/auth/login.py:8-18"],
            description="Login handler missing brute-force protection",
            rationale="Brute-force protection absent; enforce account lockout after N failures.",
        )

        results = deduplicate_region_findings([f_a, f_b])

        assert len(results) == 1, (
            f"Expected 1 deduplicated finding for same-severity overlap, got {len(results)}: {results!r}"
        )
        merged = results[0]
        has_merged_rationale = "merged_rationale" in merged and merged["merged_rationale"]
        assert not has_merged_rationale, (
            f"Expected no merged_rationale for equal-severity merge, got {merged.get('merged_rationale')!r}"
        )


class TestClaimFingerprintDedupRegardlessOfLineRange:
    """Findings with the same description (claim-fingerprint) are deduped even if line ranges do not overlap."""

    def test_claim_fingerprint_dedup_regardless_of_line_range(self) -> None:
        """Given: two findings with same description (same claim-fingerprint)
        but NON-overlapping line ranges
        When: deduplicate_region_findings is called
        Then: still deduplicated (fingerprint match wins)
        """
        shared_description = "SQL query constructed via string concatenation allows injection"
        f_a = _make_finding(
            severity="critical",
            cited_lines=["src/auth/login.py:10-20"],
            description=shared_description,
            rationale="Line 15 concatenates user input directly into query string.",
        )
        f_b = _make_finding(
            severity="critical",
            cited_lines=["src/auth/login.py:80-90"],  # non-overlapping with 10-20
            description=shared_description,
            rationale="Line 85 also concatenates user input into a query string.",
        )

        results = deduplicate_region_findings([f_a, f_b])

        assert len(results) == 1, (
            f"Expected 1 finding after claim-fingerprint dedup (same description, "
            f"non-overlapping lines), got {len(results)}: {results!r}"
        )


class TestNonOverlappingDifferentClaimsNotDeduped:
    """Findings with non-overlapping ranges AND different descriptions are both preserved."""

    def test_non_overlapping_different_claims_not_deduped(self) -> None:
        """Given: two findings non-overlapping ranges AND different description
        When: deduplicate_region_findings is called
        Then: both returned (no dedup)
        """
        f_a = _make_finding(
            severity="important",
            cited_lines=["src/auth/login.py:5-15"],
            description="Missing CSRF token on login form submission",
            rationale="Form at line 10 does not include CSRF token; attacker can forge requests.",
        )
        f_b = _make_finding(
            severity="suggestion",
            cited_lines=["src/auth/login.py:60-70"],
            description="Password comparison uses string equality instead of constant-time compare",
            rationale="Line 65 uses == for password comparison; switch to hmac.compare_digest.",
        )

        results = deduplicate_region_findings([f_a, f_b])

        assert len(results) == 2, (
            f"Expected 2 findings preserved (non-overlapping, different claims), "
            f"got {len(results)}: {results!r}"
        )
        severities = {r["severity"] for r in results}
        assert "important" in severities and "suggestion" in severities, (
            f"Expected both original severities preserved, got {severities!r}"
        )
