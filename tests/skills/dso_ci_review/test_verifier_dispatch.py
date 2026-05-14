"""RED unit tests for dso_ci_review.verifier dispatch module.

These tests FAIL until S4 T2 creates dso_ci_review/verifier.py.

RED marker: tests/skills/dso_ci_review/test_verifier_dispatch.py [test_minor_findings_bypass_verifier]
"""

from __future__ import annotations

import pytest
from unittest.mock import MagicMock, patch

# Import will raise ImportError until S4 T2 creates verifier.py
from dso_ci_review.verifier import (  # noqa: F401
    dispatch_verifier,
    VerifierResult,
)


class TestMinorFindingsBypass:
    """Minor severity findings must NOT be sent to the verifier."""

    def test_minor_findings_bypass_verifier(self) -> None:
        """Given: a minor-severity finding with absence language
        When: dispatch_verifier is called
        Then: finding is returned unchanged without calling the verifier agent
        """
        finding = {
            "finding_id": "f-001",
            "severity": "minor",
            "description": "The helper does not exist",
            "verification_evidence": {"command": "ls foo.py", "output": "ls: No such file"},
        }
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            result = dispatch_verifier([finding], reviewed_sha="abc123")
            mock_call.assert_not_called()
        assert result[0]["severity"] == "minor"


class TestFabricatedEvidence:
    """Evidence with mismatched command output is flagged as evidence_invalidated."""

    def test_fabricated_command_evidence_invalidated(self) -> None:
        """Given: verification_evidence.output doesn't match what git show would return
        When: dispatch_verifier is called with evidence_invalidated=True injected
        Then: finding has evidence_invalidated=True; verifier sees it and drops
        """
        finding = {
            "finding_id": "f-002",
            "severity": "important",
            "description": "The function does not exist",
            "verification_evidence": {
                "command": "grep -rn 'def missing_fn' src/",
                "output": "(no output — function not found)",
            },
        }
        verifier_ruling = VerifierResult(
            finding_id="f-002",
            ruling="drop",
            fingerprint="src/app.py:0-0",
            verifier_status="ok",
            evidence_invalidated=True,
            rationale="Evidence output is inconsistent with actual file content",
        )
        with patch("dso_ci_review.verifier._call_verifier_agent", return_value=verifier_ruling):
            result = dispatch_verifier([finding], reviewed_sha="abc123")
        assert len(result) == 0  # dropped finding removed


class TestShaConsistency:
    """reviewed_sha must be captured before dispatch and not change mid-review."""

    def test_sha_consistency_mid_review_commit(self) -> None:
        """Given: HEAD advances after reviewed_sha is captured
        When: dispatch_verifier is called with the original sha
        Then: the sha passed to verifier agent matches the captured sha, not HEAD
        """
        finding = {
            "finding_id": "f-003",
            "severity": "important",
            "description": "The module does not exist",
            "verification_evidence": {"command": "ls src/missing.py", "output": "No such file"},
        }
        captured_sha = "deadbeef"
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            mock_call.return_value = VerifierResult(
                finding_id="f-003",
                ruling="confirm",
                fingerprint="src/missing.py:0-0",
                verifier_status="ok",
                evidence_invalidated=False,
                rationale="Confirmed absence",
            )
            dispatch_verifier([finding], reviewed_sha=captured_sha)
            _, kwargs = mock_call.call_args
            assert kwargs.get("reviewed_sha", mock_call.call_args[0][1] if mock_call.call_args[0] else None) == captured_sha or \
                   mock_call.call_args[0][1] == captured_sha


class TestVerifierFailureFailOpen:
    """If verifier dispatch raises, finding passes through with verifier_status=failed."""

    def test_verifier_failure_fail_open(self) -> None:
        """Given: verifier agent raises RuntimeError
        When: dispatch_verifier is called
        Then: finding is returned with verifier_status='failed', ruling='confirm'
        """
        finding = {
            "finding_id": "f-004",
            "severity": "important",
            "description": "The class is not defined",
            "verification_evidence": {"command": "grep 'class Foo' src/", "output": ""},
        }
        with patch("dso_ci_review.verifier._call_verifier_agent", side_effect=RuntimeError("timeout")):
            result = dispatch_verifier([finding], reviewed_sha="abc123")
        assert result[0]["verifier_status"] == "failed"
        assert result[0]["severity"] == "important"  # severity unchanged on fail-open


class TestConfirmRuling:
    """confirm ruling leaves finding severity untouched."""

    def test_confirm_ruling_enters_loop_unchanged(self) -> None:
        """Given: verifier returns ruling=confirm
        When: dispatch_verifier processes the ruling
        Then: finding severity remains unchanged; finding still in results
        """
        finding = {
            "finding_id": "f-005",
            "severity": "critical",
            "description": "The method is not defined in scope",
            "verification_evidence": {"command": "grep 'def method' src/", "output": ""},
        }
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            mock_call.return_value = VerifierResult(
                finding_id="f-005",
                ruling="confirm",
                fingerprint="src/app.py:10-10",
                verifier_status="ok",
                evidence_invalidated=False,
                rationale="Uncertain — pass through",
            )
            result = dispatch_verifier([finding], reviewed_sha="abc123")
        assert result[0]["severity"] == "critical"


class TestDowngradeToMinor:
    """downgrade-to-minor ruling reduces finding severity to minor."""

    def test_downgrade_to_minor_ruling(self) -> None:
        """Given: verifier returns ruling=downgrade-to-minor
        When: dispatch_verifier processes the ruling
        Then: finding severity is set to 'minor'
        """
        finding = {
            "finding_id": "f-006",
            "severity": "important",
            "description": "No validation handler found",
            "verification_evidence": {"command": "grep 'validate' src/", "output": ""},
        }
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            mock_call.return_value = VerifierResult(
                finding_id="f-006",
                ruling="downgrade-to-minor",
                fingerprint="src/app.py:42-42",
                verifier_status="ok",
                evidence_invalidated=False,
                rationale="Validation exists elsewhere; scope overstated",
            )
            result = dispatch_verifier([finding], reviewed_sha="abc123")
        assert result[0]["severity"] == "minor"


class TestDropRuling:
    """drop ruling removes the finding from merged output."""

    def test_drop_ruling_removes_finding(self) -> None:
        """Given: verifier returns ruling=drop
        When: dispatch_verifier processes the ruling
        Then: finding is removed from results (empty list if only finding)
        """
        finding = {
            "finding_id": "f-007",
            "severity": "important",
            "description": "The function is never defined",
            "verification_evidence": {"command": "grep 'def target_fn' src/", "output": "def target_fn(x):"},
        }
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            mock_call.return_value = VerifierResult(
                finding_id="f-007",
                ruling="drop",
                fingerprint="src/app.py:15-15",
                verifier_status="ok",
                evidence_invalidated=True,
                rationale="Evidence shows function exists at line 15",
            )
            result = dispatch_verifier([finding], reviewed_sha="abc123")
        assert len(result) == 0
