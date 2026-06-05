"""Tests that the schema-correction-exhausted fail-closed path includes
schema error detail in its stderr message.

Bug ticket: 9d2c-76c2-411b-4c15

When the CI review runner's schema correction is exhausted, the fail-closed
stderr message previously omitted the actual schema-validation errors
(_schema_result.errors), making the violating field/value unrecoverable
from the CI job log.

This test suite:
  - Drives the schema_fail → correction-exhausted path via runner.main()
  - Asserts that a distinctive schema error string appears in stderr
  - Asserts that exit code is non-zero (fail-closed enforcement is preserved)
"""

from __future__ import annotations

import io
import sys
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"

# Ensure the plugin's scripts/ directory is on sys.path.
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def _standard_tier_classification():
    return {
        "selected_tier": "standard",
        "size_action": "none",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 1,
        "blast_radius": 1,
        "critical_path": 0,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 0,
        "change_volume": 0,
        "computed_total": 1,
        "is_merge_commit": False,
    }


def _make_findings_dispatch(findings_list):
    """Build a mock async_dispatch_specialists return value from a list of findings dicts."""

    async def _mock(agents):
        return [{"findings": findings_list}]

    return _mock


def test_schema_exhaustion_stderr_includes_error_detail(tmp_path):
    """
    Given: _validate_findings_schema signals schema_fail with a distinctive error string
           AND dispatch_schema_correction returns an exhausted result (synthetic schema_error)
    When: runner.main() executes
    Then: exit code is non-zero (fail-closed is preserved)
          AND the distinctive error string appears in stderr
          (so the violating field is recoverable from the CI job log)

    RED test for bug 9d2c-76c2-411b-4c15: prior code omitted _schema_result.errors
    from the fail-closed message, making the error detail unrecoverable.
    """
    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    # Distinctive error string that must appear in stderr after the fix.
    _DISTINCTIVE_ERROR = "finding[0].category: 'xyzzy' is not one of [...]"

    schema_fail_result = runner_mod._SchemaValidationResult(
        status="schema_fail",
        errors=[_DISTINCTIVE_ERROR],
    )

    # Simulate dispatch_schema_correction exhausting retries:
    # returns findings that contain a synthetic parse_error/schema_error entry.
    exhausted_result = {
        "findings": [
            {
                "severity": "suggestion",
                "category": "hygiene",
                "description": "A real finding.",
                "file": "foo.py",
                "cited_lines": ["foo.py:1"],
                "cited_excerpt": "",
            },
            {
                "type": "parse_error",
                "severity": "critical",
                "category": "schema_error",
                "description": "Schema correction failed after 2 attempt(s): xyzzy category",
                "finding_id": "schema_error_test1234",
                "file": "",
                "cited_lines": [],
                "cited_excerpt": "",
                "reachability": "",
            },
        ],
        "summary": "Schema correction applied: all attempts exhausted",
    }

    artifacts_dir = str(tmp_path / "artifacts")
    import os as _os

    _os.makedirs(artifacts_dir, exist_ok=True)

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": artifacts_dir,
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "GITHUB_SHA": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(
                [
                    {
                        "severity": "suggestion",
                        "category": "hygiene",
                        "description": "placeholder",
                        "file": "foo.py",
                        "cited_lines": ["foo.py:1"],
                        "cited_excerpt": "",
                    }
                ]
            ),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=schema_fail_result,
        ),
        patch(
            "dso_ci_review.runner.get_schema_correction_max_attempts",
            return_value=2,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            return_value=exhausted_result,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    stderr_text = stderr_capture.getvalue()

    # Enforcement must remain fail-closed.
    assert exit_code != 0, (
        f"Expected non-zero exit when schema correction exhausted; got {exit_code}. "
        f"stderr={stderr_text!r}"
    )

    # The distinctive error detail MUST appear in the fail-closed stderr message.
    assert _DISTINCTIVE_ERROR in stderr_text, (
        f"Expected schema error detail {_DISTINCTIVE_ERROR!r} to appear in stderr, "
        f"but it was absent. stderr={stderr_text!r}\n"
        "This is the diagnosability bug: the violating field is unrecoverable from the CI log."
    )
