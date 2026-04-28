"""RED tests for plugins/dso/scripts/fix-bug/gate-escalation-router.py.

These tests are RED — gate-escalation-router.py does not yet exist.
All tests must FAIL until the script is implemented.

The script reads a JSON array of gate signal objects from stdin:

  [
    {"gate_id": "feature_request", "triggered": true, "signal_type": "primary", ...},
    {"gate_id": "blast_radius", "triggered": true, "signal_type": "modifier", ...},
    ...
  ]

It accepts an optional --complex flag to force escalation regardless of
primary signal count.

It outputs a single JSON routing decision object to stdout and exits 0:

  route          — one of "auto-fix", "dialog", "escalate"
  signal_count   — integer count of triggered primary signals
  dialog_context — object with question_count and signal details (present
                   when route="dialog"); includes modifier evidence when
                   a modifier signal is triggered

Routing rules:
  0 triggered primary signals          → route: "auto-fix"
  1 triggered primary signal           → route: "dialog"
  2+ triggered primary signals         → route: "escalate"
  --complex flag present               → route: "escalate" (always)

Modifier signals (signal_type="modifier") are NOT counted toward
signal_count but may enrich dialog_context when route="dialog".

Missing/absent gate entries in the input array default to not-triggered
(signal_count contribution = 0) rather than crashing.

Malformed JSON input → route: "auto-fix" (fail-open, not crash), exit 0.

Test: python3 -m pytest tests/scripts/test_gate_escalation_router.py
All tests must fail before gate-escalation-router.py is implemented.
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
    REPO_ROOT / "plugins" / "dso" / "scripts" / "fix-bug" / "gate-escalation-router.py"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_signal(
    gate_id: str,
    triggered: bool,
    signal_type: str = "primary",
    evidence: str = "test evidence",
    confidence: str = "high",
) -> dict:
    """Build a gate signal dict conforming to gate-signal-schema.md."""
    return {
        "gate_id": gate_id,
        "triggered": triggered,
        "signal_type": signal_type,
        "evidence": evidence,
        "confidence": confidence,
    }


def _run(
    signals: list[dict],
    extra_args: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Pipe a JSON array of gate signals to gate-escalation-router.py."""
    payload = json.dumps(signals)
    cmd = [sys.executable, str(SCRIPT_PATH)] + (extra_args or [])
    return subprocess.run(
        cmd,
        input=payload,
        capture_output=True,
        text=True,
    )


def _parse(result: subprocess.CompletedProcess[str]) -> dict:
    """Parse stdout as JSON; return empty dict on failure."""
    try:
        return json.loads(result.stdout.strip())
    except (json.JSONDecodeError, ValueError):
        return {}


# ---------------------------------------------------------------------------
# Fixture — fails (RED) when script is absent
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session", autouse=True)
def script_must_exist() -> None:
    """Fail all tests immediately if gate-escalation-router.py is absent."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"gate-escalation-router.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestGateEscalationRouter:
    """Behavioral tests: JSON array of gate signals via stdin → routing JSON."""

    # ── Test 1: zero signals → auto-fix ──────────────────────────────────────

    def test_zero_signals(self) -> None:
        """Empty array (all-false) routes to auto-fix with signal_count=0."""
        signals = [
            _make_signal("1b", triggered=False),
            _make_signal("2a", triggered=False),
            _make_signal("2c", triggered=False),
            _make_signal("2d", triggered=False),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "auto-fix", (
            f"Expected route='auto-fix' for zero triggered signals; got: {data.get('route')!r}\n"
            f"full output: {data}"
        )
        assert data.get("signal_count") == 0, (
            f"Expected signal_count=0; got: {data.get('signal_count')!r}"
        )

    # ── Test 2: one primary signal → dialog ───────────────────────────────────

    def test_one_primary_signal(self) -> None:
        """Exactly one triggered primary signal routes to dialog."""
        signals = [
            _make_signal("1b", triggered=True, signal_type="primary"),
            _make_signal("2a", triggered=False, signal_type="primary"),
            _make_signal("2c", triggered=False, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "dialog", (
            f"Expected route='dialog' for one triggered primary signal; "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )

    # ── Test 3: two primary signals → escalate ────────────────────────────────

    def test_two_primary_signals(self) -> None:
        """Two triggered primary signals routes to escalate."""
        signals = [
            _make_signal("1b", triggered=True, signal_type="primary"),
            _make_signal("2a", triggered=True, signal_type="primary"),
            _make_signal("2c", triggered=False, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "escalate", (
            f"Expected route='escalate' for two triggered primary signals; "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )

    # ── Test 4: three primary signals → escalate ──────────────────────────────

    def test_three_primary_signals(self) -> None:
        """Three triggered primary signals routes to escalate."""
        signals = [
            _make_signal("1b", triggered=True, signal_type="primary"),
            _make_signal("2a", triggered=True, signal_type="primary"),
            _make_signal("2c", triggered=True, signal_type="primary"),
            _make_signal("2d", triggered=False, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "escalate", (
            f"Expected route='escalate' for three triggered primary signals; "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )
        assert data.get("signal_count") == 3, (
            f"Expected signal_count=3; got: {data.get('signal_count')!r}"
        )

    # ── Test 5: --complex flag with signals → escalate ────────────────────────

    def test_complex_override(self) -> None:
        """--complex flag forces escalate even when only one primary signal fired."""
        signals = [
            _make_signal("1b", triggered=True, signal_type="primary"),
            _make_signal("2a", triggered=False, signal_type="primary"),
        ]
        result = _run(signals, extra_args=["--complex"])
        assert result.returncode == 0, (
            f"Expected exit 0 with --complex; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "escalate", (
            f"Expected route='escalate' when --complex passed (would otherwise be 'dialog'); "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )

    # ── Test 6: --complex with zero signals → escalate ────────────────────────

    def test_complex_with_zero_signals(self) -> None:
        """--complex flag forces escalate even when zero primary signals fired."""
        signals = [
            _make_signal("1b", triggered=False, signal_type="primary"),
            _make_signal("2a", triggered=False, signal_type="primary"),
        ]
        result = _run(signals, extra_args=["--complex"])
        assert result.returncode == 0, (
            f"Expected exit 0 with --complex + zero signals; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "escalate", (
            f"Expected route='escalate' when --complex passed with zero signals; "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )

    # ── Test 7: modifier not counted as primary signal ─────────────────────────

    def test_modifier_not_counted(self) -> None:
        """A triggered modifier signal is NOT counted toward signal_count or route threshold."""
        signals = [
            _make_signal("1b", triggered=False, signal_type="primary"),
            _make_signal(
                "2b",
                triggered=True,
                signal_type="modifier",
                evidence="high blast radius: 47 files affected",
            ),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "auto-fix", (
            f"Expected route='auto-fix' when only modifier triggered (not primary); "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )
        assert data.get("signal_count") == 0, (
            f"Expected signal_count=0 (modifier not counted); "
            f"got: {data.get('signal_count')!r}"
        )

    # ── Test 8: modifier enriches dialog_context ──────────────────────────────

    def test_modifier_enriches_dialog(self) -> None:
        """One primary + triggered modifier: route=dialog with modifier evidence in dialog_context."""
        modifier_evidence = (
            "blast radius: 23 files potentially affected across 4 modules"
        )
        signals = [
            _make_signal(
                "2a",
                triggered=True,
                signal_type="primary",
                evidence="reversal pattern detected",
            ),
            _make_signal(
                "2b", triggered=True, signal_type="modifier", evidence=modifier_evidence
            ),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "dialog", (
            f"Expected route='dialog'; got: {data.get('route')!r}\nfull output: {data}"
        )
        dialog_context = data.get("dialog_context")
        assert dialog_context is not None, (
            f"Expected dialog_context field present when route='dialog'; "
            f"full output: {data}"
        )
        # The modifier's evidence field value must appear in dialog_context
        context_str = json.dumps(dialog_context)
        assert modifier_evidence in context_str, (
            f"Expected modifier evidence {modifier_evidence!r} in dialog_context; "
            f"dialog_context: {dialog_context!r}"
        )

    # ── Test 9: dialog format has question_count and signal details ────────────

    def test_dialog_format(self) -> None:
        """route=dialog output includes question_count and signal details in dialog_context."""
        signals = [
            _make_signal(
                "2c",
                triggered=True,
                signal_type="primary",
                evidence="assertion count dropped from 5 to 2",
            ),
            _make_signal("2a", triggered=False, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "dialog", (
            f"Expected route='dialog'; got: {data.get('route')!r}\nfull output: {data}"
        )
        dialog_context = data.get("dialog_context")
        assert dialog_context is not None, (
            f"Expected dialog_context in route=dialog output; full output: {data}"
        )
        question_count = (
            dialog_context.get("question_count")
            if isinstance(dialog_context, dict)
            else None
        )
        assert question_count is not None, (
            f"Expected question_count field in dialog_context; "
            f"dialog_context: {dialog_context!r}"
        )
        assert isinstance(question_count, int), (
            f"Expected question_count to be an integer; got: {type(question_count).__name__}"
        )
        assert 1 <= question_count <= 2, (
            f"Expected question_count between 1 and 2 (inline dialog); "
            f"got: {question_count}"
        )

    # ── Test 10: escalate format includes all evidence ─────────────────────────

    def test_escalate_format(self) -> None:
        """route=escalate output includes all triggered signal evidence in the response."""
        evidence_1 = "feature request language detected in title"
        evidence_2 = "reversal pattern matched 3 git commits"
        signals = [
            _make_signal(
                "1b", triggered=True, signal_type="primary", evidence=evidence_1
            ),
            _make_signal(
                "2a", triggered=True, signal_type="primary", evidence=evidence_2
            ),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "escalate", (
            f"Expected route='escalate'; got: {data.get('route')!r}\nfull output: {data}"
        )
        # All triggered evidence strings must appear somewhere in the output
        output_str = json.dumps(data)
        assert evidence_1 in output_str, (
            f"Expected evidence from gate 1b in escalate output; "
            f"evidence: {evidence_1!r}\nfull output: {data}"
        )
        assert evidence_2 in output_str, (
            f"Expected evidence from gate 2a in escalate output; "
            f"evidence: {evidence_2!r}\nfull output: {data}"
        )

    # ── Test 11: missing gate entries default to 0 — no error ─────────────────

    def test_missing_gate_defaults(self) -> None:
        """Partial array (some gates absent) does not crash; present gates still counted."""
        # Only include two gates instead of a full 1a/1b/2a/2b/2c/2d array
        signals = [
            _make_signal("2d", triggered=True, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0 with partial gate array; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert "route" in data, (
            f"Expected 'route' field in output even with partial gate array; "
            f"full output: {data}"
        )
        assert "signal_count" in data, (
            f"Expected 'signal_count' field in output; full output: {data}"
        )
        # One gate triggered, so signal_count should be 1 and route should be dialog
        assert data.get("signal_count") == 1, (
            f"Expected signal_count=1 for one present triggered gate; "
            f"got: {data.get('signal_count')!r}"
        )

    # ── Test 12: output always has route, signal_count, dialog_context ─────────

    def test_emits_routing_json(self) -> None:
        """Output JSON always contains route, signal_count, and dialog_context fields."""
        signals = [
            _make_signal("1b", triggered=False, signal_type="primary"),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert "route" in data, (
            f"Expected 'route' field in routing JSON; full output: {data}"
        )
        assert "signal_count" in data, (
            f"Expected 'signal_count' field in routing JSON; full output: {data}"
        )
        assert "dialog_context" in data, (
            f"Expected 'dialog_context' field in routing JSON; full output: {data}"
        )
        assert data.get("route") in ("auto-fix", "dialog", "escalate"), (
            f"Expected route to be one of auto-fix/dialog/escalate; "
            f"got: {data.get('route')!r}"
        )

    # ── Test 13 (AC amendment): modifier evidence field used, not annotation ───

    def test_modifier_enriches_dialog_uses_evidence_field(self) -> None:
        """dialog_context includes modifier's 'evidence' field value (not 'annotation')."""
        modifier_evidence = "47 files in blast radius across core domain"
        signals = [
            _make_signal(
                "2c",
                triggered=True,
                signal_type="primary",
                evidence="test assertion count dropped",
            ),
            _make_signal(
                "2b", triggered=True, signal_type="modifier", evidence=modifier_evidence
            ),
        ]
        result = _run(signals)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "dialog", (
            f"Expected route='dialog'; got: {data.get('route')!r}\nfull output: {data}"
        )
        context_str = json.dumps(data.get("dialog_context", {}))
        assert modifier_evidence in context_str, (
            f"Expected modifier 'evidence' value {modifier_evidence!r} in dialog_context "
            f"(per gate-signal-schema.md contract, field is 'evidence' not 'annotation'); "
            f"dialog_context: {data.get('dialog_context')!r}"
        )

    # ── Test 14 (AC amendment): malformed JSON → fail-open auto-fix ───────────

    def test_malformed_json_input(self) -> None:
        """Malformed JSON on stdin → route:auto-fix (fail-open), exit 0, no crash."""
        garbage = "this is not valid JSON [[[{{{}}}"
        cmd = [sys.executable, str(SCRIPT_PATH)]
        result = subprocess.run(
            cmd,
            input=garbage,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"Expected graceful exit 0 for malformed JSON; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse(result)
        assert data.get("route") == "auto-fix", (
            f"Expected route='auto-fix' (fail-open) for malformed JSON input; "
            f"got: {data.get('route')!r}\nfull output: {data}"
        )
