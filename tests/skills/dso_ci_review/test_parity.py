"""
Parity tests for dso_ci_review — verifies the golden findings baseline.

These tests ensure that:
1. The expected-findings.json golden fixture exists.
2. The fixture conforms to the required schema.
3. No critical/important/fragile findings are dropped relative to the golden
   baseline when the runner is invoked in dry-run mode.

Testing mode: RED — these tests were written before the parity fixture was
populated with real findings.  The dry-run path returns an empty findings
list, so test_parity_zero_dropped_findings verifies that no baseline findings
are absent from the runner output.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus"
EXPECTED_FINDINGS_PATH = FIXTURE_DIR / "expected-findings.json"
FIXTURE_DIFF_PATH = FIXTURE_DIR / "fixture-diff.txt"

# Severities considered high-signal — losing these findings is a parity failure.
_HIGH_SIGNAL_SEVERITIES = {"critical", "important", "fragile"}


def test_parity_golden_fixture_exists():
    """
    Given: the test suite is installed in its expected layout
    When: the tests directory is inspected
    Then: tests/fixtures/ci-review-corpus/expected-findings.json exists on disk
    """
    assert EXPECTED_FINDINGS_PATH.exists(), (
        f"Golden fixture not found at {EXPECTED_FINDINGS_PATH}. "
        "Run the fixture bootstrap step to generate it."
    )


def test_parity_fixture_has_required_schema():
    """
    Given: tests/fixtures/ci-review-corpus/expected-findings.json exists
    When: the file is parsed as JSON
    Then: the top-level dict contains both 'findings' (a list) and 'version' (a string)
    """
    assert EXPECTED_FINDINGS_PATH.exists(), (
        f"Golden fixture not found at {EXPECTED_FINDINGS_PATH}."
    )

    data = json.loads(EXPECTED_FINDINGS_PATH.read_text(encoding="utf-8"))

    assert "findings" in data, (
        f"'findings' key missing from expected-findings.json. Got keys: {list(data.keys())}"
    )
    assert isinstance(data["findings"], list), (
        f"'findings' must be a list, got {type(data['findings'])}"
    )
    assert "version" in data, (
        f"'version' key missing from expected-findings.json. Got keys: {list(data.keys())}"
    )
    assert isinstance(data["version"], str), (
        f"'version' must be a string, got {type(data['version'])}"
    )


def test_parity_zero_dropped_findings(tmp_path):
    """
    Given: fixture-diff.txt and expected-findings.json golden baseline
    When: dso_ci_review.runner is invoked in dry-run mode (no real LLM calls)
    Then: every critical/important/fragile finding in the golden baseline
          is present in the runner output — no high-signal findings are dropped.

    The dry-run path returns an empty findings list; when the baseline itself
    has no high-signal findings (findings == []), the assertion trivially passes
    because there are zero dropped findings.  When the baseline is later
    populated with real findings, this test will detect regressions.
    """
    assert FIXTURE_DIFF_PATH.exists(), f"Fixture diff not found at {FIXTURE_DIFF_PATH}."
    assert EXPECTED_FINDINGS_PATH.exists(), (
        f"Golden fixture not found at {EXPECTED_FINDINGS_PATH}."
    )

    # Load the baseline high-signal findings.
    baseline = json.loads(EXPECTED_FINDINGS_PATH.read_text(encoding="utf-8"))
    baseline_high_signal = [
        f for f in baseline["findings"] if f.get("severity") in _HIGH_SIGNAL_SEVERITIES
    ]

    # Invoke the runner in dry-run mode — no real API calls.
    diff_file = tmp_path / "input.diff"
    diff_file.write_bytes(FIXTURE_DIFF_PATH.read_bytes())
    output_file = tmp_path / "findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "DSO_CI_REVIEW_DRY_RUN": "1",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin"),
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, (
        f"runner exited {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert output_file.exists(), (
        f"output file not written to {output_file}. stdout={result.stdout!r}"
    )

    actual = json.loads(output_file.read_text(encoding="utf-8"))
    assert "findings" in actual, f"'findings' key missing from runner output: {actual}"

    # Build a description set for the actual findings for fast lookup.
    actual_descriptions = {
        f.get("description", "")
        for f in actual["findings"]
        if f.get("severity") in _HIGH_SIGNAL_SEVERITIES
    }

    dropped = [
        f
        for f in baseline_high_signal
        if f.get("description", "") not in actual_descriptions
    ]

    assert dropped == [], (
        f"Parity regression: {len(dropped)} high-signal finding(s) from the golden "
        f"baseline are absent from runner output.\n"
        f"Dropped findings:\n"
        + "\n".join(
            f"  [{f.get('severity')}] {f.get('description', '')} "
            f"(cited: {f.get('cited_lines', [])})"
            for f in dropped
        )
    )
