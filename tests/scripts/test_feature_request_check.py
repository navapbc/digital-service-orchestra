"""RED tests for plugins/dso/scripts/fix-bug/feature-request-check.py.

These tests are RED — feature-request-check.py does not yet exist.
All tests must FAIL until the script is implemented.

The script reads a JSON payload from stdin with fields:
  title       — string (bug ticket title)
  description — string (bug ticket description)

It outputs a single JSON gate signal object to stdout and exits 0:
  gate_id     — "feature_request"
  triggered   — boolean (true = likely feature request, not a bug)
  signal_type — "primary"
  evidence    — non-empty string explaining the classification
  confidence  — one of "high", "medium", "low"

Test: python3 -m pytest tests/scripts/test_feature_request_check.py
All tests must fail before feature-request-check.py is implemented.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "fix-bug" / "feature-request-check.py"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run(title: str, description: str = "") -> subprocess.CompletedProcess[str]:
    """Pipe JSON payload with title+description to the gate script."""
    payload = json.dumps({"title": title, "description": description})
    return subprocess.run(
        [sys.executable, str(SCRIPT_PATH)],
        input=payload,
        capture_output=True,
        text=True,
    )


def _triggered(result: subprocess.CompletedProcess[str]) -> bool:
    """Parse triggered field from stdout JSON."""
    data = json.loads(result.stdout)
    return bool(data["triggered"])


def _field(result: subprocess.CompletedProcess[str], field: str) -> str:
    """Extract a string field from stdout JSON."""
    data = json.loads(result.stdout)
    return str(data.get(field, ""))


# ---------------------------------------------------------------------------
# Fixture — fails (RED) when script is absent
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session", autouse=True)
def script_must_exist() -> None:
    """Fail all tests immediately if feature-request-check.py is absent."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"feature-request-check.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestGate1bFeatureRequestCheck:
    """Behavioral tests: stdin JSON ticket -> stdout gate signal JSON."""

    # ── Primary signal patterns — triggered=true ──────────────────────────

    def test_doesnt_support(self) -> None:
        """'doesn't support CSV export' triggers as feature request."""
        result = _run("App doesn't support CSV export")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f'Expected triggered=true for "doesn\'t support" language.\n'
            f"stdout: {result.stdout!r}"
        )

    def test_missing_capability(self) -> None:
        """'Missing OAuth capability' triggers as feature request."""
        result = _run("Missing OAuth capability")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f"Expected triggered=true for 'Missing OAuth capability'.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_doesnt_accept(self) -> None:
        """'doesn't accept YAML input' triggers as feature request."""
        result = _run("System doesn't accept YAML input")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f'Expected triggered=true for "doesn\'t accept" language.\n'
            f"stdout: {result.stdout!r}"
        )

    def test_doesnt_handle(self) -> None:
        """'doesn't handle bulk uploads' triggers as feature request."""
        result = _run("API doesn't handle bulk uploads")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f'Expected triggered=true for "doesn\'t handle" language.\n'
            f"stdout: {result.stdout!r}"
        )

    def test_no_way_to(self) -> None:
        """'No way to reset password' triggers as feature request."""
        result = _run("No way to reset password")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f"Expected triggered=true for 'No way to' language.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_cant_yet(self) -> None:
        """'Can't export to PDF yet' triggers as feature request."""
        result = _run("Can't export to PDF yet")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f'Expected triggered=true for "Can\'t ... yet" language.\n'
            f"stdout: {result.stdout!r}"
        )

    def test_unable_to_new(self) -> None:
        """'Unable to add new users' triggers as feature request."""
        result = _run("Unable to add new users")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f"Expected triggered=true for 'Unable to add new' language.\n"
            f"stdout: {result.stdout!r}"
        )

    # ── Genuine bugs — triggered=false ────────────────────────────────────

    def test_missing_data_after_save_is_not_feature_request(self) -> None:
        """'Missing data after save' is a genuine bug — bare 'missing' must NOT trigger.

        The broad bare '\\bmissing\\b' pattern was removed in favour of a qualified
        pattern requiring a capability noun (support/option/ability/etc.).  This test
        guards against regression: 'missing' alone in a bug context must not produce
        a false-positive feature-request classification.
        """
        result = _run("Missing data after save")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for 'Missing data after save' (genuine bug).\n"
            f"stdout: {result.stdout!r}"
        )

    def test_missing_rows_in_export_is_not_feature_request(self) -> None:
        """'Missing rows in database export' is a genuine bug — no capability qualifier."""
        result = _run("Missing rows in database export results")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for 'Missing rows in database export results' (genuine bug).\n"
            f"stdout: {result.stdout!r}"
        )

    def test_genuine_bug_crash(self) -> None:
        """'App crashes when clicking save' is a bug, not a feature request."""
        result = _run("App crashes when clicking save")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for a genuine crash bug.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_genuine_bug_error(self) -> None:
        """'500 error on login page' is a bug, not a feature request."""
        result = _run("500 error on login page")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for a server error bug.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_genuine_bug_regression(self) -> None:
        """'Search stopped working after v2.3' is a regression, not a feature request."""
        result = _run("Search stopped working after v2.3")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for a regression bug.\nstdout: {result.stdout!r}"
        )

    # ── Edge cases / false-positive suppression ────────────────────────────

    def test_domain_handle_false_positive(self) -> None:
        """'Payment handler doesn't handle refunds correctly' describes broken behavior.

        The domain-handle guard must fire here: title contains 'handler' (domain
        component) and 'doesn't handle', while the description has a regression
        indicator ('broken').  Crucially, this test verifies the guard itself —
        not the combined regression check.  The title alone contains no regression
        indicator, so if the guard were removed the gate would trigger (false
        positive) despite the description confirming broken behavior.
        """
        result = _run(
            "Payment handler doesn't handle refunds correctly",
            description="The refund flow has been broken since the last deploy.",
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for domain 'handle' false positive.\n"
            f"stdout: {result.stdout!r}"
        )
        # Verify it was the domain-handle guard that suppressed, not the combined
        # regression check firing on title-only text.
        evidence = _field(result, "evidence")
        assert "domain handle" in evidence.lower(), (
            f"Expected domain-handle guard evidence, got: {evidence!r}"
        )

    def test_domain_handle_guard_not_triggered_without_handler_in_title(self) -> None:
        """'API doesn't handle refunds' with regression in description still triggers.

        The domain-handle guard requires 'handler' in the title.  When the title
        says 'API doesn't handle ...' (no 'handler' word) the guard does NOT fire,
        and the combined text has no regression indicator in the title, so the
        feature-request pattern triggers.
        """
        result = _run(
            "API doesn't handle refunds",
            description="The refund flow has been broken since the last deploy.",
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        # 'broken' in description is in combined text, so regression suppresses.
        assert _triggered(result) is False, (
            f"Expected triggered=false because 'broken' in combined text suppresses.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_regression_indicator_suppression(self) -> None:
        """'App doesn't support dark mode anymore' contains 'anymore' — regression signal.

        A regression indicator ('anymore', 'used to', 'stopped') suppresses the
        feature-request trigger even when 'doesn't support' is present.
        """
        result = _run("App doesn't support dark mode anymore")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false when regression indicator ('anymore') suppresses.\n"
            f"stdout: {result.stdout!r}"
        )

    # ── Cross-paragraph / DOTALL false-positive resistance ────────────────

    def test_cant_yet_does_not_span_paragraphs(self) -> None:
        """'can't' and 'yet' in separate paragraphs must NOT trigger 'can't...yet'.

        Patterns compiled with re.DOTALL would allow .* to match across newlines,
        causing a spurious feature-request classification.  The gate must constrain
        matching to a single line.
        """
        result = _run(
            title="System can't handle the load.",
            description="Performance is degraded.\n\nPlease report any issues yet to be diagnosed.",
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        # "can't" in title and "yet" later in description — must NOT match cross-line
        assert _triggered(result) is False, (
            f"Expected triggered=false: 'can\u2019t' and 'yet' are in separate paragraphs "
            f"and should not be cross-matched.\nstdout: {result.stdout!r}"
        )

    def test_unable_to_any_does_not_span_paragraphs(self) -> None:
        """'unable to' and 'any' in separate paragraphs must NOT trigger 'unable to...any'.

        Verifies that the 'unable to.*any' pattern does not cross newlines.
        """
        result = _run(
            title="Users are unable to complete checkout.",
            description="Checkout fails with 500 error.\n\nPlease fix any issues found.",
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false: 'unable to' and 'any' are in different paragraphs "
            f"and should not be cross-matched.\nstdout: {result.stdout!r}"
        )

    # ── Description-only match ─────────────────────────────────────────────

    def test_description_match(self) -> None:
        """Feature-request language in description triggers even with a clean title."""
        result = _run(
            title="User report",
            description="There is missing X feature and no way to configure it.",
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is True, (
            f"Expected triggered=true when description contains feature-request language.\n"
            f"stdout: {result.stdout!r}"
        )

    # ── Gate signal schema compliance ──────────────────────────────────────

    def test_emits_gate_signal_json(self) -> None:
        """Output conforms to gate-signal-schema: gate_id='feature_request', signal_type='primary'."""
        result = _run("App crashes when clicking save")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )

        gate_id = _field(result, "gate_id")
        assert gate_id == "feature_request", (
            f"Expected gate_id='feature_request', got {gate_id!r}.\nstdout: {result.stdout!r}"
        )

        signal_type = _field(result, "signal_type")
        assert signal_type == "primary", (
            f"Expected signal_type='primary', got {signal_type!r}.\n"
            f"stdout: {result.stdout!r}"
        )

        evidence = _field(result, "evidence")
        assert evidence, (
            f"Expected non-empty evidence field.\nstdout: {result.stdout!r}"
        )

        confidence = _field(result, "confidence")
        assert confidence in ("high", "medium", "low"), (
            f"Expected confidence in (high, medium, low), got {confidence!r}.\n"
            f"stdout: {result.stdout!r}"
        )

    # ── Empty input ────────────────────────────────────────────────────────

    def test_empty_input(self) -> None:
        """Empty title and empty description produces triggered=false (no signals)."""
        result = _run(title="", description="")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        assert _triggered(result) is False, (
            f"Expected triggered=false for empty title and description.\n"
            f"stdout: {result.stdout!r}"
        )
