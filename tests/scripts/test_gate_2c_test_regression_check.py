"""RED tests for plugins/dso/scripts/gate-2c-test-regression-check.py.

These tests are RED — gate-2c-test-regression-check.py does not yet exist.
All tests must FAIL until the script is implemented.

The script accepts a unified diff via stdin and an optional --test-dir flag.
It analyzes test file changes in the diff and emits a JSON gate signal:

  gate_id     — "2c"
  triggered   — bool: True if assertion regression detected
  signal_type — "primary"
  evidence    — string describing what was detected
  confidence  — "high" / "medium" / "low"

Trigger policy: triggered if ANY of the following is detected in test files:
  - Assertion removal
  - Specificity reduction (e.g., assertEqual → assertIsNotNone)
  - Assertion count reduction
  - @pytest.mark.skip added
  - @pytest.mark.xfail added
  - Literal expected value replaced by variable (assertEqual(x, 42) → assertEqual(x, result))

NOT triggered for:
  - One specific value swapped for another specific value
  - New assertions added (count increase)
  - Diffs that touch only non-test source files
  - --intent-aligned flag passed (suppresses all signals)

Test: python3 -m pytest tests/scripts/test_gate_2c_test_regression_check.py
All tests must fail before gate-2c-test-regression-check.py is implemented.
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
    REPO_ROOT / "plugins" / "dso" / "scripts" / "gate-2c-test-regression-check.py"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _unified_diff(
    filename: str, before_lines: list[str], after_lines: list[str]
) -> str:
    """Build a minimal unified diff string for the given filename."""
    # Header lines
    lines = [
        f"--- a/{filename}",
        f"+++ b/{filename}",
        f"@@ -1,{len(before_lines)} +1,{len(after_lines)} @@",
    ]
    for line in before_lines:
        lines.append(f"-{line}")
    for line in after_lines:
        lines.append(f"+{line}")
    return "\n".join(lines) + "\n"


def _run(
    diff_text: str, extra_args: list[str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Pipe a unified diff to gate-2c-test-regression-check.py and return result."""
    cmd = [sys.executable, str(SCRIPT_PATH)] + (extra_args or [])
    return subprocess.run(
        cmd,
        input=diff_text,
        capture_output=True,
        text=True,
    )


def _parse_output(result: subprocess.CompletedProcess[str]) -> dict:
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
    """Fail all tests immediately if gate-2c-test-regression-check.py is absent."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"gate-2c-test-regression-check.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestGate2cTestRegressionCheck:
    """Behavioral tests: pipe unified diffs to the script, assert on JSON output."""

    # ── Test 1: assertion removal → triggered ──────────────────────────────

    def test_removes_assertion(self, tmp_path: Path) -> None:
        """Removing an assertEqual from a test file triggers gate 2c."""
        before = [
            "def test_foo():",
            "    result = do_thing()",
            "    assertEqual(result, 42)",
            "    assertEqual(result.status, 'ok')",
        ]
        after = [
            "def test_foo():",
            "    result = do_thing()",
            "    assertEqual(result.status, 'ok')",
        ]
        diff = _unified_diff("tests/test_foo.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when assertion removed; got: {data}"
        )

    # ── Test 2: specificity reduction → triggered ─────────────────────────

    def test_broadens_matcher(self, tmp_path: Path) -> None:
        """Replacing assertEqual(x, 42) with assertIsNotNone(x) triggers gate 2c."""
        before = [
            "def test_value():",
            "    result = compute()",
            "    assertEqual(result, 42)",
        ]
        after = [
            "def test_value():",
            "    result = compute()",
            "    assertIsNotNone(result)",
        ]
        diff = _unified_diff("tests/test_value.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when assertEqual→assertIsNotNone; got: {data}"
        )

    # ── Test 3: assertion count reduction → triggered ─────────────────────

    def test_reduces_assertion_count(self, tmp_path: Path) -> None:
        """Reducing assertion count from 5 to 3 triggers gate 2c."""
        before = [
            "def test_many():",
            "    assertEqual(a, 1)",
            "    assertEqual(b, 2)",
            "    assertEqual(c, 3)",
            "    assertEqual(d, 4)",
            "    assertEqual(e, 5)",
        ]
        after = [
            "def test_many():",
            "    assertEqual(a, 1)",
            "    assertEqual(b, 2)",
            "    assertEqual(c, 3)",
        ]
        diff = _unified_diff("tests/test_many.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when assertion count drops from 5→3; got: {data}"
        )

    # ── Test 4: @pytest.mark.skip added → triggered ────────────────────────

    def test_adds_skip(self, tmp_path: Path) -> None:
        """Adding @pytest.mark.skip to a test triggers gate 2c."""
        before = [
            "def test_important():",
            "    assertEqual(result, 'pass')",
        ]
        after = [
            "@pytest.mark.skip(reason='broken')",
            "def test_important():",
            "    assertEqual(result, 'pass')",
        ]
        diff = _unified_diff("tests/test_important.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when @pytest.mark.skip added; got: {data}"
        )

    # ── Test 5: @pytest.mark.xfail added → triggered ──────────────────────

    def test_adds_xfail(self, tmp_path: Path) -> None:
        """Adding @pytest.mark.xfail to a test triggers gate 2c."""
        before = [
            "def test_behavior():",
            "    assertEqual(x, 10)",
        ]
        after = [
            "@pytest.mark.xfail",
            "def test_behavior():",
            "    assertEqual(x, 10)",
        ]
        diff = _unified_diff("tests/test_behavior.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when @pytest.mark.xfail added; got: {data}"
        )

    # ── Test 6: specific-to-specific int → NOT triggered ──────────────────

    def test_specific_to_specific_int(self, tmp_path: Path) -> None:
        """Changing assertEqual(x, 42) to assertEqual(x, 57) does NOT trigger gate 2c."""
        before = [
            "def test_int():",
            "    assertEqual(result, 42)",
        ]
        after = [
            "def test_int():",
            "    assertEqual(result, 57)",
        ]
        diff = _unified_diff("tests/test_int.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false for int literal swap 42→57; got: {data}"
        )

    # ── Test 7: specific-to-specific str → NOT triggered ──────────────────

    def test_specific_to_specific_str(self, tmp_path: Path) -> None:
        """Changing assertEqual(x, 'foo') to assertEqual(x, 'bar') does NOT trigger gate 2c."""
        before = [
            "def test_str():",
            "    assertEqual(result, 'foo')",
        ]
        after = [
            "def test_str():",
            "    assertEqual(result, 'bar')",
        ]
        diff = _unified_diff("tests/test_str.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false for string literal swap 'foo'→'bar'; got: {data}"
        )

    # ── Test 8: literal to variable → triggered ───────────────────────────

    def test_specific_to_variable(self, tmp_path: Path) -> None:
        """Replacing a literal expected value with a variable triggers gate 2c."""
        before = [
            "def test_specific():",
            "    assertEqual(result, 42)",
        ]
        after = [
            "def test_specific():",
            "    assertEqual(result, expected_result)",
        ]
        diff = _unified_diff("tests/test_specific.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when literal 42 replaced by variable; got: {data}"
        )

    # ── Test 9: adds assertion → NOT triggered ────────────────────────────

    def test_adds_assertion(self, tmp_path: Path) -> None:
        """Adding a new assertion does NOT trigger gate 2c."""
        before = [
            "def test_grow():",
            "    assertEqual(result, 1)",
        ]
        after = [
            "def test_grow():",
            "    assertEqual(result, 1)",
            "    assertEqual(result.status, 'ok')",
        ]
        diff = _unified_diff("tests/test_grow.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false when assertion count increases; got: {data}"
        )

    # ── Test 10: --intent-aligned suppression → NOT triggered ─────────────

    def test_intent_aligned_suppression(self, tmp_path: Path) -> None:
        """With --intent-aligned flag, assertion removal does NOT trigger gate 2c."""
        before = [
            "def test_aligned():",
            "    assertEqual(result, 42)",
            "    assertEqual(status, 'ok')",
        ]
        after = [
            "def test_aligned():",
            "    assertEqual(result, 42)",
        ]
        diff = _unified_diff("tests/test_aligned.py", before, after)
        result = _run(diff, extra_args=["--intent-aligned"])
        assert result.returncode == 0, (
            f"Expected exit 0 with --intent-aligned; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false when --intent-aligned passed; got: {data}"
        )

    # ── Test 11: diff of only source files → NOT triggered ────────────────

    def test_no_test_files(self, tmp_path: Path) -> None:
        """Diff that touches only source files (no tests/) does NOT trigger gate 2c."""
        before = [
            "def compute():",
            "    return 42",
        ]
        after = [
            "def compute():",
            "    return 57",
        ]
        diff = _unified_diff("src/compute.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false when diff touches only source files; got: {data}"
        )

    # ── Test 12: gate signal schema fields ────────────────────────────────

    def test_emits_gate_signal_json(self, tmp_path: Path) -> None:
        """Script always emits gate_id='2c' and signal_type='primary' in output."""
        before = [
            "def test_x():",
            "    assertEqual(x, 1)",
        ]
        after = [
            "def test_x():",
            "    assertEqual(x, 1)",
        ]
        diff = _unified_diff("tests/test_x.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("gate_id") == "2c", (
            f"Expected gate_id='2c'; got: {data.get('gate_id')!r}"
        )
        assert data.get("signal_type") == "primary", (
            f"Expected signal_type='primary'; got: {data.get('signal_type')!r}"
        )

    # ── Test 13: malformed diff → NOT triggered (graceful) ────────────────

    def test_malformed_diff(self, tmp_path: Path) -> None:
        """Non-parseable diff input does not crash; exits 0 with triggered=false."""
        garbage = "this is not a valid unified diff\ngarbage\n!!!\n"
        result = _run(garbage)
        assert result.returncode == 0, (
            f"Expected graceful exit 0 for malformed diff; got {result.returncode}.\n"
            f"stderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is False, (
            f"Expected triggered=false for malformed input; got: {data}"
        )

    # ── Test 14: mixed removal + addition → triggered ─────────────────────

    def test_mixed_removal_and_addition(self, tmp_path: Path) -> None:
        """File with both assertion removal AND assertion addition triggers gate 2c."""
        before = [
            "def test_mixed():",
            "    assertEqual(result, 42)",
            "    assertEqual(status, 'ok')",
        ]
        after = [
            "def test_mixed():",
            "    assertEqual(status, 'ok')",
            "    assertEqual(name, 'alice')",
            "    assertEqual(count, 5)",
        ]
        diff = _unified_diff("tests/test_mixed.py", before, after)
        result = _run(diff)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr: {result.stderr!r}"
        )
        data = _parse_output(result)
        assert data.get("triggered") is True, (
            f"Expected triggered=true when assertion removed even alongside additions; got: {data}"
        )
