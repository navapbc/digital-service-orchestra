"""Tests for dso_ci_review.verifier.dispatch_verifier (S4 T2, cbdd-834c).

Testing mode: RED → GREEN — these tests define the required behavior of the
dispatch_verifier function and VerifierResult dataclass.

Behavioral contracts under test:
1. Minor-severity findings bypass _call_verifier_agent entirely; returned as-is.
2. Verifier ruling "drop" removes the finding from results (empty list).
3. reviewed_sha is forwarded verbatim to _call_verifier_agent (SHA consistency).
4. _call_verifier_agent raising any exception → fail-open: verifier_status="failed",
   severity unchanged, finding included in results.
5. Ruling "confirm" → finding returned, severity unchanged.
6. Ruling "downgrade-to-minor" → finding["severity"] set to "minor".
7. Ruling "drop" → finding removed from results.
"""

from __future__ import annotations

import pathlib
import sys

import pytest

# ---------------------------------------------------------------------------
# Path setup: ensure the plugin scripts directory takes precedence over the
# test package so `dso_ci_review.verifier` resolves to the plugin module.
# ---------------------------------------------------------------------------

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.verifier as _verifier_mod  # noqa: E402
from dso_ci_review.verifier import (  # noqa: E402
    VerifierResult,
    dispatch_verifier,
)


@pytest.fixture(autouse=True)
def _enable_verifier(monkeypatch):
    """Force verifier enabled for all dispatch behavior tests."""
    monkeypatch.setattr(_verifier_mod, "_is_verifier_enabled", lambda: True)

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

_CAPTURED_SHA = "abc123def456abc123def456abc123def456abc1"

_CONFIRM_RESULT = VerifierResult(
    finding_id="f-001",
    ruling="confirm",
    fingerprint="foo.py:10-20",
    verifier_status="ok",
    evidence_invalidated=False,
    rationale="Evidence still present at reviewed SHA.",
)

_DROP_RESULT = VerifierResult(
    finding_id="f-001",
    ruling="drop",
    fingerprint="foo.py:10-20",
    verifier_status="ok",
    evidence_invalidated=True,
    rationale="Evidence no longer present; finding fabricated.",
)

_DOWNGRADE_RESULT = VerifierResult(
    finding_id="f-001",
    ruling="downgrade-to-minor",
    fingerprint="foo.py:10-20",
    verifier_status="ok",
    evidence_invalidated=False,
    rationale="Issue exists but is not actionable at this severity.",
)


def _make_finding(severity: str = "important") -> dict:
    return {
        "severity": severity,
        "description": "Example finding",
        "cited_lines": ["foo.py:10"],
    }


# ---------------------------------------------------------------------------
# TestMinorFindingsBypass
# ---------------------------------------------------------------------------


class TestMinorFindingsBypass:
    """Minor findings bypass the verifier entirely."""

    def test_minor_finding_not_sent_to_verifier(self, monkeypatch) -> None:
        """Given: a finding with severity="minor"
        When: dispatch_verifier is called
        Then:
          - _call_verifier_agent is NOT called
          - The finding is returned unchanged (no verifier_status added)
        """
        call_count = [0]

        def _mock_call(finding, reviewed_sha):
            call_count[0] += 1
            return _CONFIRM_RESULT

        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", _mock_call)

        finding = _make_finding(severity="minor")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert call_count[0] == 0, (
            f"_call_verifier_agent must NOT be called for minor findings, "
            f"but was called {call_count[0]} time(s)"
        )
        assert len(result) == 1, f"Minor finding must be returned; got: {result}"
        assert "verifier_status" not in result[0], (
            "Minor finding must NOT have verifier_status added; "
            f"got keys: {list(result[0].keys())}"
        )
        assert result[0]["severity"] == "minor"

    def test_minor_finding_returned_unchanged(self, monkeypatch) -> None:
        """Given: a minor finding with extra fields
        When: dispatch_verifier is called
        Then: the returned dict is identical to the input (no mutation)
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _CONFIRM_RESULT,
        )

        finding = {
            "severity": "minor",
            "description": "Style nit",
            "cited_lines": ["bar.py:5"],
            "custom_field": "preserved",
        }
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result[0] == finding, (
            f"Minor finding must be returned byte-for-byte identical. "
            f"Expected: {finding}, Got: {result[0]}"
        )


# ---------------------------------------------------------------------------
# TestFabricatedEvidence
# ---------------------------------------------------------------------------


class TestFabricatedEvidence:
    """Verifier ruling 'drop' removes the finding from results."""

    def test_drop_ruling_removes_finding(self, monkeypatch) -> None:
        """Given: verifier returns ruling="drop"
        When: dispatch_verifier is called with one important finding
        Then: the result is an empty list
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _DROP_RESULT,
        )

        finding = _make_finding(severity="important")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result == [], (
            f"Finding with drop ruling must be removed; got: {result}"
        )


# ---------------------------------------------------------------------------
# TestShaConsistency
# ---------------------------------------------------------------------------


class TestShaConsistency:
    """reviewed_sha is forwarded verbatim to _call_verifier_agent."""

    def test_reviewed_sha_forwarded_to_verifier(self, monkeypatch) -> None:
        """Given: dispatch_verifier is called with reviewed_sha=captured_sha
        When: _call_verifier_agent is invoked for a non-minor finding
        Then: the sha received by _call_verifier_agent equals captured_sha
        """
        captured_sha = "deadbeef" * 5  # 40-char hex

        received_shas: list[str] = []

        def _mock_call(finding, reviewed_sha):
            received_shas.append(reviewed_sha)
            return _CONFIRM_RESULT

        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", _mock_call)

        finding = _make_finding(severity="important")
        dispatch_verifier([finding], reviewed_sha=captured_sha)

        assert received_shas, "_call_verifier_agent was not called"
        assert received_shas[0] == captured_sha, (
            f"reviewed_sha must be forwarded verbatim. "
            f"Expected: {captured_sha!r}, got: {received_shas[0]!r}"
        )

    def test_sha_via_call_args(self, monkeypatch) -> None:
        """Alternative: verify SHA via mock call_args (keyword or positional)."""
        from unittest.mock import MagicMock

        mock_call = MagicMock(return_value=_CONFIRM_RESULT)
        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", mock_call)

        finding = _make_finding(severity="critical")
        dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert mock_call.called, "_call_verifier_agent must be called for critical findings"
        _, kwargs = mock_call.call_args
        sha_received = kwargs.get("reviewed_sha") or mock_call.call_args[0][1]
        assert sha_received == _CAPTURED_SHA, (
            f"reviewed_sha must equal captured_sha={_CAPTURED_SHA!r}, "
            f"got: {sha_received!r}"
        )


# ---------------------------------------------------------------------------
# TestVerifierFailureFailOpen
# ---------------------------------------------------------------------------


class TestVerifierFailureFailOpen:
    """On any exception from _call_verifier_agent → fail-open."""

    def test_exception_annotates_with_failed_status(self, monkeypatch) -> None:
        """Given: _call_verifier_agent raises RuntimeError
        When: dispatch_verifier is called
        Then:
          - result contains the finding (not empty)
          - result[0]["verifier_status"] == "failed"
          - severity is unchanged
        """

        def _always_raise(finding, reviewed_sha):
            raise RuntimeError("Simulated verifier agent failure")

        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", _always_raise)

        finding = _make_finding(severity="important")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert len(result) == 1, (
            f"Finding must be kept on verifier failure (fail-open); got: {result}"
        )
        assert result[0]["verifier_status"] == "failed", (
            f"verifier_status must be 'failed' on exception; got: {result[0]}"
        )
        assert result[0]["severity"] == "important", (
            f"Severity must not be changed on verifier failure; got: {result[0]}"
        )

    def test_exception_type_does_not_matter(self, monkeypatch) -> None:
        """Given: _call_verifier_agent raises ValueError (not RuntimeError)
        When: dispatch_verifier is called
        Then: still fail-open — verifier_status="failed", finding included
        """

        def _raise_value_error(finding, reviewed_sha):
            raise ValueError("Unexpected agent output format")

        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", _raise_value_error)

        finding = _make_finding(severity="critical")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result, "Finding must be included on verifier failure"
        assert result[0].get("verifier_status") == "failed"
        assert result[0]["severity"] == "critical"


# ---------------------------------------------------------------------------
# TestConfirmRuling
# ---------------------------------------------------------------------------


class TestConfirmRuling:
    """Ruling 'confirm' → finding returned, severity unchanged."""

    def test_confirm_ruling_returns_finding(self, monkeypatch) -> None:
        """Given: verifier returns ruling="confirm"
        When: dispatch_verifier is called
        Then: finding is in results with severity unchanged
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _CONFIRM_RESULT,
        )

        finding = _make_finding(severity="important")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert len(result) == 1, f"Confirmed finding must be returned; got: {result}"
        assert result[0]["severity"] == "important", (
            f"Severity must not change on confirm; got: {result[0]}"
        )
        assert result[0].get("verifier_status") == "ok", (
            f"verifier_status must be set from VerifierResult; got: {result[0]}"
        )

    def test_confirm_preserves_all_original_fields(self, monkeypatch) -> None:
        """Given: finding has extra custom fields
        When: confirmed by verifier
        Then: all original fields are preserved in the result
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _CONFIRM_RESULT,
        )

        finding = {
            "severity": "critical",
            "description": "Null deref",
            "cited_lines": ["main.py:42"],
            "extra_field": "preserved",
        }
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result[0]["extra_field"] == "preserved", (
            f"Original finding fields must be preserved on confirm; got: {result[0]}"
        )


# ---------------------------------------------------------------------------
# TestDowngradeToMinor
# ---------------------------------------------------------------------------


class TestDowngradeToMinor:
    """Ruling 'downgrade-to-minor' → finding["severity"] set to "minor"."""

    def test_downgrade_sets_severity_to_minor(self, monkeypatch) -> None:
        """Given: verifier returns ruling="downgrade-to-minor"
        When: dispatch_verifier is called with an important finding
        Then: result[0]["severity"] == "minor"
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _DOWNGRADE_RESULT,
        )

        finding = _make_finding(severity="important")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert len(result) == 1, f"Downgraded finding must be returned; got: {result}"
        assert result[0]["severity"] == "minor", (
            f"severity must be 'minor' after downgrade; got: {result[0]}"
        )

    def test_downgrade_sets_verifier_status(self, monkeypatch) -> None:
        """Given: verifier returns ruling="downgrade-to-minor"
        When: dispatch_verifier is called
        Then: verifier_status is set from VerifierResult
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _DOWNGRADE_RESULT,
        )

        finding = _make_finding(severity="critical")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result[0].get("verifier_status") == "ok", (
            f"verifier_status must be set on downgrade; got: {result[0]}"
        )


# ---------------------------------------------------------------------------
# TestDropRuling
# ---------------------------------------------------------------------------


class TestDropRuling:
    """Ruling 'drop' → finding removed from results."""

    def test_drop_ruling_empties_results(self, monkeypatch) -> None:
        """Given: verifier returns ruling="drop"
        When: dispatch_verifier is called with one critical finding
        Then: result is an empty list
        """
        monkeypatch.setattr(
            _verifier_mod,
            "_call_verifier_agent",
            lambda f, reviewed_sha: _DROP_RESULT,
        )

        finding = _make_finding(severity="critical")
        result = dispatch_verifier([finding], reviewed_sha=_CAPTURED_SHA)

        assert result == [], (
            f"Finding with drop ruling must be removed from results; got: {result}"
        )

    def test_drop_one_of_two_findings(self, monkeypatch) -> None:
        """Given: two findings; verifier drops the first, confirms the second
        When: dispatch_verifier is called
        Then: result contains only the second finding
        """
        call_count = [0]

        def _selective_drop(finding, reviewed_sha):
            call_count[0] += 1
            if call_count[0] == 1:
                return _DROP_RESULT
            return _CONFIRM_RESULT

        monkeypatch.setattr(_verifier_mod, "_call_verifier_agent", _selective_drop)

        findings = [
            _make_finding(severity="important"),
            {"severity": "important", "description": "Second finding", "cited_lines": ["bar.py:1"]},
        ]
        result = dispatch_verifier(findings, reviewed_sha=_CAPTURED_SHA)

        assert len(result) == 1, (
            f"Only the confirmed finding should remain; got: {result}"
        )
        assert result[0]["description"] == "Second finding", (
            f"The confirmed finding must be in results; got: {result[0]}"
        )


# ---------------------------------------------------------------------------
# TestVerifierResult
# ---------------------------------------------------------------------------


class TestVerifierResult:
    """VerifierResult dataclass shape and field validation."""

    def test_verifier_result_has_required_fields(self) -> None:
        """VerifierResult can be instantiated with all required fields."""
        vr = VerifierResult(
            finding_id="f-001",
            ruling="confirm",
            fingerprint="foo.py:1-10",
            verifier_status="ok",
            evidence_invalidated=False,
            rationale="All good.",
        )
        assert vr.finding_id == "f-001"
        assert vr.ruling == "confirm"
        assert vr.fingerprint == "foo.py:1-10"
        assert vr.verifier_status == "ok"
        assert vr.evidence_invalidated is False
        assert vr.rationale == "All good."

    def test_verifier_result_sentinel_fingerprint(self) -> None:
        """path:0-0 is accepted as a sentinel fingerprint."""
        vr = VerifierResult(
            finding_id="f-002",
            ruling="drop",
            fingerprint="unknown.py:0-0",
            verifier_status="ok",
            evidence_invalidated=True,
            rationale="No line info.",
        )
        assert vr.fingerprint == "unknown.py:0-0"
