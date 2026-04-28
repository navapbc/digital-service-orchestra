"""RED tests for plugins/dso/scripts/validate-gate-signal.py.

These tests are RED — validate-gate-signal.py does not yet exist.
All tests must FAIL until the script is implemented.

The script reads a JSON payload from stdin, validates it against the gate signal
schema defined in plugins/dso/docs/contracts/gate-signal-schema.md, and:
  - exits 0 with structured output on valid input
  - exits non-zero on any validation failure

Required schema fields (all required):
  gate_id     — string
  triggered   — boolean (not string)
  signal_type — string, one of: "primary", "modifier"
  evidence    — string (must not be empty)
  confidence  — string, one of: "high", "medium", "low"

Test: python3 -m pytest tests/scripts/test_validate_gate_signal.py
All tests must fail before validate-gate-signal.py is implemented.
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
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "validate-gate-signal.py"

# A fully valid signal payload conforming to the gate-signal-schema contract.
VALID_SIGNAL = {
    "gate_id": "intent",
    "triggered": True,
    "signal_type": "primary",
    "evidence": "Stack trace found with 3 distinct frame references",
    "confidence": "high",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run(payload: object) -> subprocess.CompletedProcess[str]:
    """Pipe JSON-serialized payload to validate-gate-signal.py and return result."""
    stdin_text = json.dumps(payload) if not isinstance(payload, str) else payload
    return subprocess.run(
        [sys.executable, str(SCRIPT_PATH)],
        input=stdin_text,
        capture_output=True,
        text=True,
    )


# ---------------------------------------------------------------------------
# Fixture — fails (RED) when script is absent
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session", autouse=True)
def script_must_exist() -> None:
    """Fail all tests immediately if validate-gate-signal.py is not present."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"validate-gate-signal.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestValidateGateSignal:
    """Behavioral tests for validate-gate-signal.py: stdin JSON → exit code + stdout."""

    def test_valid_complete_signal(self) -> None:
        """A fully valid signal with all required fields exits 0."""
        result = _run(VALID_SIGNAL)
        assert result.returncode == 0, (
            f"Expected exit 0 for valid signal, got {result.returncode}.\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )

    def test_missing_gate_id(self) -> None:
        """Signal missing gate_id must exit non-zero."""
        payload = {k: v for k, v in VALID_SIGNAL.items() if k != "gate_id"}
        result = _run(payload)
        assert result.returncode != 0, (
            f"Expected non-zero exit when gate_id is missing, got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_missing_triggered(self) -> None:
        """Signal missing triggered field must exit non-zero."""
        payload = {k: v for k, v in VALID_SIGNAL.items() if k != "triggered"}
        result = _run(payload)
        assert result.returncode != 0, (
            f"Expected non-zero exit when triggered is missing, got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_invalid_signal_type(self) -> None:
        """signal_type not in ['primary', 'modifier'] must exit non-zero."""
        payload = {**VALID_SIGNAL, "signal_type": "unknown"}
        result = _run(payload)
        assert result.returncode != 0, (
            f"Expected non-zero exit for invalid signal_type 'unknown', got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_wrong_triggered_type(self) -> None:
        """triggered as a string instead of bool must exit non-zero."""
        payload = {**VALID_SIGNAL, "triggered": "true"}
        result = _run(payload)
        assert result.returncode != 0, (
            f"Expected non-zero exit when triggered is string 'true', got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_empty_json_object(self) -> None:
        """Empty JSON object {} (no fields at all) must exit non-zero."""
        result = _run({})
        assert result.returncode != 0, (
            f"Expected non-zero exit for empty object, got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_malformed_json(self) -> None:
        """Non-JSON input string must exit non-zero."""
        result = _run("this is not json at all")
        assert result.returncode != 0, (
            f"Expected non-zero exit for malformed JSON, got {result.returncode}.\n"
            f"stdout: {result.stdout!r}"
        )

    def test_valid_stdout_content(self) -> None:
        """Valid signal produces non-empty stdout containing structured output."""
        result = _run(VALID_SIGNAL)
        assert result.returncode == 0, (
            f"Expected exit 0 for valid signal, got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        assert result.stdout.strip(), (
            "Expected non-empty stdout for valid signal, got empty output."
        )
        # The output should contain the gate_id so the caller can confirm
        # which signal was validated — this is the minimal structured signal
        # that demonstrates the script processed the input, not just silently exited.
        assert "intent" in result.stdout, (
            f"Expected gate_id 'intent' to appear in stdout, got: {result.stdout!r}"
        )
