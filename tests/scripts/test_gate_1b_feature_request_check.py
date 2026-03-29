"""RED tests for plugins/dso/scripts/gate-1b-feature-request-check.py.

These tests are RED — gate-1b-feature-request-check.py does not yet exist.
All tests must FAIL until the script is implemented.

The script reads a JSON payload from stdin with fields:
  title       — string (bug ticket title)
  description — string (bug ticket description)

It outputs a single JSON gate signal object to stdout and exits 0:
  gate_id     — "1b"
  triggered   — boolean (true = likely feature request, not a bug)
  signal_type — "primary"
  evidence    — non-empty string explaining the classification
  confidence  — one of "high", "medium", "low"

Test: python3 -m pytest tests/scripts/test_gate_1b_feature_request_check.py
All tests must fail before gate-1b-feature-request-check.py is implemented.
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
    REPO_ROOT / "plugins" / "dso" / "scripts" / "gate-1b-feature-request-check.py"
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
    """Fail all tests immediately if gate-1b-feature-request-check.py is absent."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"gate-1b-feature-request-check.py not found at {SCRIPT_PATH} — "
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

        The word 'handle' appears twice but the context is an existing capability
        behaving incorrectly, not a missing feature. Should not trigger.
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
        """Output conforms to gate-signal-schema: gate_id='1b', signal_type='primary'."""
        result = _run("App crashes when clicking save")
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}.\nstderr: {result.stderr!r}"
        )

        gate_id = _field(result, "gate_id")
        assert gate_id == "1b", (
            f"Expected gate_id='1b', got {gate_id!r}.\nstdout: {result.stdout!r}"
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
