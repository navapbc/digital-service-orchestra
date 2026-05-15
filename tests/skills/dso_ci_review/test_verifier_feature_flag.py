"""RED unit tests for verifier feature flag, threshold, cascade brake, and telemetry.

These tests FAIL until S6 T2 implements feature flag support in verifier.py/runner.py.

RED marker: tests/skills/dso_ci_review/test_verifier_feature_flag.py [test_verifier_disabled_by_default_skips_dispatch]
"""

from __future__ import annotations

import pytest
from unittest.mock import patch


class TestVerifierFeatureFlag:
    """review.verifier_enabled flag controls whether verifier runs."""

    def test_verifier_disabled_by_default_skips_dispatch(self) -> None:
        """Flag absent → verifier not called; findings returned unchanged."""
        from dso_ci_review.verifier import dispatch_verifier
        finding = {
            "finding_id": "f-001",
            "severity": "important",
            "description": "The function does not exist",
            "verification_evidence": {"command": "grep fn src/", "output": ""},
        }
        # When flag is absent (default), dispatch_verifier should skip verifier agent
        # and return findings unchanged. Currently this FAILS because the function
        # does not check for any flag — it always calls verifier.
        with patch("dso_ci_review.verifier._call_verifier_agent") as mock_call:
            with patch("dso_ci_review.verifier._is_verifier_enabled", return_value=False):
                result = dispatch_verifier([finding], reviewed_sha="abc123")
                mock_call.assert_not_called()
        assert result[0]["severity"] == "important"

    def test_verifier_enabled_true_calls_dispatch(self) -> None:
        """Flag=true → verifier called with critical/important/fragile findings."""
        from dso_ci_review.verifier import dispatch_verifier, VerifierResult
        finding = {
            "finding_id": "f-002",
            "severity": "important",
            "description": "The class is not defined",
            "verification_evidence": {"command": "grep class src/", "output": ""},
        }
        ruling = VerifierResult(
            finding_id="f-002",
            ruling="confirm",
            fingerprint="src/app.py:0-0",
            verifier_status="ok",
            evidence_invalidated=False,
            rationale="Confirmed",
        )
        with patch("dso_ci_review.verifier._is_verifier_enabled", return_value=True):
            with patch("dso_ci_review.verifier._call_verifier_agent", return_value=ruling) as mock_call:
                dispatch_verifier([finding], reviewed_sha="abc123")
                mock_call.assert_called_once()


class TestVerifierThreshold:
    """review.verifier_failure_threshold range validation."""

    def test_threshold_below_range_rejected(self) -> None:
        """threshold=0.0 → ValueError."""
        from dso_ci_review.verifier import _validate_failure_threshold
        with pytest.raises(ValueError, match="threshold"):
            _validate_failure_threshold(0.0)

    def test_threshold_above_range_rejected(self) -> None:
        """threshold=1.1 → ValueError."""
        from dso_ci_review.verifier import _validate_failure_threshold
        with pytest.raises(ValueError, match="threshold"):
            _validate_failure_threshold(1.1)


class TestCascadeBrake:
    """Cascading-failure brake activates when failure_rate > threshold AND 5+ in-scope findings."""

    def test_cascade_brake_activates_at_threshold_with_5_findings(self) -> None:
        """failure_rate > 0.30 AND 5+ findings → pause signal."""
        from dso_ci_review.verifier import _check_cascade_brake
        result = _check_cascade_brake(failure_rate=0.40, in_scope_count=5)
        assert result is True

    def test_cascade_brake_skipped_below_5_findings(self) -> None:
        """failure_rate > 0.30 but only 3 findings → no brake."""
        from dso_ci_review.verifier import _check_cascade_brake
        result = _check_cascade_brake(failure_rate=0.40, in_scope_count=3)
        assert result is False


class TestTelemetry:
    """Verifier output contains telemetry fields."""

    def test_telemetry_fields_present_in_output(self) -> None:
        """dispatch_verifier returns telemetry in a summary dict alongside findings."""
        from dso_ci_review.verifier import dispatch_verifier_with_telemetry, VerifierResult
        findings = [
            {
                "finding_id": f"f-{i:03d}",
                "severity": "important",
                "description": "does not exist",
                "verification_evidence": {"command": "grep fn src/", "output": ""},
            }
            for i in range(3)
        ]
        rulings = [
            VerifierResult(finding_id=f"f-{i:03d}", ruling="confirm", fingerprint="src/a.py:0-0",
                          verifier_status="ok", evidence_invalidated=False, rationale="ok")
            for i in range(3)
        ]
        with patch("dso_ci_review.verifier._is_verifier_enabled", return_value=True):
            with patch("dso_ci_review.verifier._call_verifier_agent", side_effect=rulings):
                result, telemetry = dispatch_verifier_with_telemetry(findings, reviewed_sha="abc123")
        assert "verifier_confirm_count" in telemetry
        assert "verifier_downgrade_count" in telemetry
        assert "verifier_drop_count" in telemetry
        assert "verifier_failure_rate" in telemetry
        assert "verifier_minor_finding_rate" in telemetry
        assert "verifier_fingerprints" in telemetry
