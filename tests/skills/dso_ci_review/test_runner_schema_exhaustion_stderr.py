"""Tests that the schema-correction-exhausted fail-closed path includes
schema error detail in its stderr message.

Bug ticket: 9d2c-76c2-411b-4c15

When the CI review runner's schema correction is exhausted, the fail-closed
stderr message previously omitted the actual schema-validation errors
(_schema_result.errors), making the violating field/value unrecoverable
from the CI job log.

These tests drive the schema_fail -> correction-exhausted path via
runner.main() and assert on the REAL error-formatting logic in runner.py
(the `_err_preview` interpolation + `[:10]` truncation + `(+N more)` overflow
suffix). `_validate_findings_schema` and `dispatch_schema_correction` are
mocked to return synthetic results because the real validator is an external
subprocess and the real correction loop requires a live LLM dispatch — neither
is exercisable in a unit test. The mocks supply the inputs (the schema-error
list and the exhausted findings); the assertions verify the runner's own
formatting/truncation output, which is the behavior under test.
"""

from __future__ import annotations

import io
import os
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


def _run_exhaustion_path(tmp_path, schema_errors):
    """Drive runner.main() through the schema-correction-exhausted fail-closed path.

    `schema_errors` is the list returned by the (mocked) schema validator. The
    runner's REAL error-formatting logic (truncation + overflow suffix +
    interpolation into the stderr message) is what executes and is what the
    callers assert on. Returns (exit_code, stderr_text).
    """
    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    schema_fail_result = runner_mod._SchemaValidationResult(
        status="schema_fail",
        errors=list(schema_errors),
    )

    # Simulate dispatch_schema_correction exhausting retries: returns findings
    # that contain a synthetic parse_error/schema_error entry (the marker the
    # runner uses to detect exhaustion).
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
                "description": "Schema correction failed after 2 attempt(s).",
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
    os.makedirs(artifacts_dir, exist_ok=True)

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

    return exit_code, stderr_capture.getvalue()


def test_schema_exhaustion_stderr_includes_error_detail(tmp_path):
    """A single schema error must be interpolated verbatim into the fail-closed stderr.

    RED test for bug 9d2c-76c2-411b-4c15: prior code omitted _schema_result.errors
    from the fail-closed message, so this distinctive string was absent. The
    assertion fails if `_err_preview` is not interpolated into the message —
    i.e., it pins the interpolation behavior, not just mock passthrough.
    Also confirms enforcement stays fail-closed (non-zero exit).
    """
    distinctive_error = "finding[0].category: 'xyzzy' is not one of [...]"
    exit_code, stderr_text = _run_exhaustion_path(tmp_path, [distinctive_error])

    assert exit_code != 0, (
        f"Expected non-zero exit when schema correction exhausted; got {exit_code}. "
        f"stderr={stderr_text!r}"
    )
    assert distinctive_error in stderr_text, (
        f"Expected schema error detail {distinctive_error!r} to appear in stderr, "
        f"but it was absent. stderr={stderr_text!r}\n"
        "Diagnosability bug: the violating field is unrecoverable from the CI log."
    )


def test_schema_exhaustion_stderr_truncates_and_counts_overflow(tmp_path):
    """With >10 errors, the message keeps the first 10, drops the rest, and counts overflow.

    Exercises the REAL truncation logic (runner.py: `_err_lines[:10]` +
    `(+N more)` suffix). Without this case the single-error test above would not
    detect a silently-broken slice or overflow count. Twelve distinct errors:
    the first 10 must appear, the 11th/12th must NOT, and "(+2 more)" must be
    present.
    """
    errors = [
        f"finding[{i}].category: 'bad{i:02d}' is not one of [...]" for i in range(12)
    ]
    exit_code, stderr_text = _run_exhaustion_path(tmp_path, errors)

    assert exit_code != 0, f"Expected non-zero (fail-closed) exit; got {exit_code}."

    # First 10 present.
    for err in errors[:10]:
        assert err in stderr_text, (
            f"Expected {err!r} (within first 10) in stderr; stderr={stderr_text!r}"
        )
    # 11th and 12th truncated away.
    for err in errors[10:]:
        assert err not in stderr_text, (
            f"Expected {err!r} (beyond the 10-error cap) to be truncated, but it appeared. "
            f"stderr={stderr_text!r}"
        )
    # Overflow count present and correct (12 - 10 = 2).
    assert "(+2 more)" in stderr_text, (
        f"Expected overflow suffix '(+2 more)' for 12 errors capped at 10; stderr={stderr_text!r}"
    )


def test_schema_exhaustion_stderr_tolerates_non_string_errors(tmp_path):
    """Non-string entries in _schema_result.errors must not crash the fail-closed path.

    PR #684 review finding: `"; ".join(_err_lines[:10])` would raise TypeError on a
    non-string entry (None/dict/int) and crash the fail-closed branch. The str()
    coercion must keep the path graceful (still exits non-zero / fail-closed) while
    surfacing the string entries.
    """
    errors = [{"unexpected": "dict"}, None, "a real error string", 42]
    exit_code, stderr_text = _run_exhaustion_path(tmp_path, errors)

    assert exit_code != 0, (
        f"Expected non-zero (fail-closed) exit even with non-string error entries; got {exit_code}."
    )
    assert "a real error string" in stderr_text, (
        f"Expected the string entry to still be surfaced; stderr={stderr_text!r}"
    )
