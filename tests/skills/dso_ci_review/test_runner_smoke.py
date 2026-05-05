"""
Smoke test for dso_ci_review.runner module.

Tests the subprocess invocation path end-to-end using dry-run mode and
the get_provider() routing path (ConfigError / AuthError exits).
Also verifies the atomic write behavior (DD3): output is written via temp+rename,
so no partial file is observable to concurrent parsers.
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


def test_runner_writes_atomically(fixture_diff_path, tmp_path):
    """
    Given: DSO_CI_REVIEW_OUTPUT_PATH set to a file in a temp directory
    When: dso_ci_review.runner completes successfully in dry-run mode
    Then: no .tmp file remains in the output directory (temp+rename was used atomically)
         AND the output file contains valid JSON (not a partial write)

    This test verifies DD3: atomic write via temp file + os.replace() so that parsers
    never observe a partially-written file.
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

    # No .tmp files should remain — temp file was renamed to final path
    leftover_tmp = list(tmp_path.glob("*.tmp"))
    assert leftover_tmp == [], (
        f"Leftover .tmp files found after atomic write: {leftover_tmp}. "
        "os.replace() must remove the temp file by renaming it to the final path."
    )

    # Output file must be fully valid JSON (not truncated / partially written)
    assert output_file.exists(), f"output file not written to {output_file}"
    content = output_file.read_text()
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        raise AssertionError(
            f"Output file is not valid JSON — partial write suspected: {exc}\n"
            f"Content: {content!r}"
        ) from exc
    assert "findings" in parsed, f"'findings' key missing from output: {parsed}"


def test_runner_output_goes_to_file_not_stdout(fixture_diff_path, tmp_path):
    """
    Given: DSO_CI_REVIEW_OUTPUT_PATH is set
    When: dso_ci_review.runner completes in dry-run mode
    Then: stdout is empty (output written to file, not stdout)

    Verifies that the atomic-write path does not accidentally duplicate output to stdout.
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

    assert result.returncode == 0
    assert result.stdout.strip() == "", (
        f"stdout should be empty when DSO_CI_REVIEW_OUTPUT_PATH is set, "
        f"got: {result.stdout!r}"
    )


def test_runner_config_error_exits_1(fixture_diff_path, tmp_path):
    """
    Given: no CI_REVIEW_PROVIDER configured and no DSO_CI_REVIEW_DRY_RUN
    When: dso_ci_review.runner is invoked with a non-empty diff
    Then: exit code is 1 and stderr contains 'ERROR: provider config:'
    (verifies get_provider() ConfigError path is reached, not hardcoded anthropic import)
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        # No CI_REVIEW_PROVIDER, no DSO_CI_REVIEW_DRY_RUN
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 1, (
        f"Expected exit code 1 (ConfigError), got {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert "ERROR: provider config:" in result.stderr, (
        f"Expected 'ERROR: provider config:' in stderr, got: {result.stderr!r}"
    )


def test_runner_auth_error_exits_1(fixture_diff_path, tmp_path):
    """
    Given: CI_REVIEW_PROVIDER=anthropic but ANTHROPIC_API_KEY absent
    When: dso_ci_review.runner is invoked with a non-empty diff
    Then: exit code is 1 and stderr contains 'ERROR: provider auth:'
    (verifies get_provider() AuthError path is reached)
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        # ANTHROPIC_API_KEY deliberately absent
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 1, (
        f"Expected exit code 1 (AuthError), got {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert "ERROR: provider auth:" in result.stderr, (
        f"Expected 'ERROR: provider auth:' in stderr, got: {result.stderr!r}"
    )
