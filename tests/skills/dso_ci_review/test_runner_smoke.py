"""
Smoke test for dso_ci_review.runner module.

Tests the subprocess invocation path end-to-end using dry-run mode.
"""

import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus"


def test_runner_produces_findings_json(fixture_diff_path, tmp_path):
    """
    Given: a fixture diff file and DSO_CI_REVIEW_OUTPUT_PATH set to a temp file
    When: dso_ci_review.runner is invoked as a subprocess in dry-run mode
    Then: exit code is 0, output file exists and contains valid JSON with a 'findings' list
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())
    output_file = tmp_path / "findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "DSO_CI_REVIEW_DRY_RUN": "1",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
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

    # DSO_CI_REVIEW_OUTPUT_PATH was set — runner MUST write to the file, not stdout
    assert output_file.exists(), (
        f"output file not written to {output_file}. stdout={result.stdout!r}"
    )

    parsed = json.loads(output_file.read_text())
    assert "findings" in parsed, f"'findings' key missing from output: {parsed}"
    assert isinstance(parsed["findings"], list), (
        f"'findings' must be a list, got {type(parsed['findings'])}"
    )
