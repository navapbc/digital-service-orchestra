"""RED tests for bug 9788 runner defensive guard: empty diff in PR context.

Bug 9788 regression: the dispatcher (llm-review-dispatch-or-skip.sh) failed to
supply the PR diff to the runner after the S3.T3 wrapper refactor, which
caused runner.py:_read_diff() to return an empty string and the runner to
short-circuit at line 1730 with `{"findings": []}` BEFORE reaching the
cycle-marker post call. PRs #252-#262 (post-regression) emitted zero markers.

Defense-in-depth fix: when the runner is invoked with empty stdin AND a PR
context is detectable (PR_NUMBER env var or pull_request GITHUB_REF), assume
the caller misconfigured the dispatch path and exit non-zero with a loud
diagnostic so the "Assert review liveness" CI invariant downstream catches
the wiring break instead of silently passing.

Negative-control case: when no PR context exists (local CLI invocation /
unit-test driver), preserve the historic exit-0 behavior so local workflows
do not regress.
"""

from __future__ import annotations

import io
import json
import os
import pathlib
import sys
from unittest.mock import patch

# Path setup is handled by conftest.py (_ensure_plugin_package), but mirror it
# here for direct pytest invocation of this file outside the package context.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402


def _run_main_with_empty_stdin(
    env: dict,
    output_path: pathlib.Path,
) -> tuple[int, str]:
    """Invoke runner.main() with empty stdin + the given env. Returns (exit_code, stderr)."""
    # Capture stderr to a StringIO so we can assert diagnostic content.
    stderr_capture = io.StringIO()
    env_full = dict(env)
    env_full["DSO_CI_REVIEW_OUTPUT_PATH"] = str(output_path)
    # Ensure no leftover DSO_CI_REVIEW_DIFF_PATH from the ambient env.
    env_full.pop("DSO_CI_REVIEW_DIFF_PATH", None)
    # Clear DRY_RUN so we exercise the production code path.
    env_full.pop("DSO_CI_REVIEW_DRY_RUN", None)

    with patch.dict(os.environ, env_full, clear=False):
        # Remove ambient vars that should be absent for this test case.
        for k in ("DSO_CI_REVIEW_DIFF_PATH", "DSO_CI_REVIEW_DRY_RUN"):
            os.environ.pop(k, None)
        with patch.object(sys, "stdin", io.StringIO("")):
            with patch.object(sys, "stderr", stderr_capture):
                exit_code = runner_mod.main()
    return exit_code, stderr_capture.getvalue()


def test_empty_diff_in_pr_context_via_pr_number_env_exits_nonzero(tmp_path):
    """PR_NUMBER set + empty stdin → exit non-zero + diagnostic + skip_reason.

    RED: before the fix, runner.main() returns 0 with `{"findings": []}` and
    no diagnostic. After the fix, it returns 1 with a stderr WARNING and a
    findings.json that includes `skip_reason: empty_diff_in_pr_context`.
    """
    output_path = tmp_path / "findings.json"
    exit_code, stderr = _run_main_with_empty_stdin(
        env={"PR_NUMBER": "99999"},
        output_path=output_path,
    )

    # Assertion A: exit code is non-zero (loud failure).
    assert exit_code != 0, (
        f"Expected non-zero exit when PR context exists with empty diff "
        f"(bug 9788 regression guard); got exit_code={exit_code}"
    )

    # Assertion B: stderr contains a diagnostic identifying the bug class.
    assert "empty diff" in stderr.lower() or "9788" in stderr, (
        f"Expected stderr to mention 'empty diff' or bug 9788; got: {stderr!r}"
    )

    # Assertion C: findings.json includes skip_reason for downstream consumers.
    assert output_path.exists(), (
        "Expected findings.json to be written even on guard failure"
    )
    data = json.loads(output_path.read_text(encoding="utf-8"))
    assert data.get("skip_reason") == "empty_diff_in_pr_context", (
        f"Expected skip_reason='empty_diff_in_pr_context' in findings.json; got: {data}"
    )


def test_empty_diff_in_pr_context_via_pull_request_ref_exits_nonzero(tmp_path):
    """pull_request GITHUB_REF + empty stdin → exit non-zero + diagnostic.

    Same as the PR_NUMBER case but via the alternate PR-context source
    (refs/pull/<N>/merge on pull_request events).
    """
    output_path = tmp_path / "findings.json"
    exit_code, stderr = _run_main_with_empty_stdin(
        env={
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_REF": "refs/pull/12345/merge",
            # Explicitly unset PR_NUMBER so the secondary path is exercised.
            "PR_NUMBER": "",
        },
        output_path=output_path,
    )

    assert exit_code != 0, (
        f"Expected non-zero exit on pull_request event with empty diff; "
        f"got exit_code={exit_code}"
    )
    assert "empty diff" in stderr.lower() or "9788" in stderr, (
        f"Expected diagnostic in stderr; got: {stderr!r}"
    )


def test_empty_diff_no_pr_context_preserves_historic_behavior(tmp_path):
    """No PR_NUMBER and no pull_request ref + empty stdin → exit 0, no warning.

    Negative-control: the defensive guard must NOT trigger for local
    invocations / unit-test drivers where there is no PR context to wire up.
    """
    output_path = tmp_path / "findings.json"
    exit_code, stderr = _run_main_with_empty_stdin(
        env={
            # Explicitly clear all PR-context signals so this is a clean
            # local-invocation simulation.
            "PR_NUMBER": "",
            "GITHUB_EVENT_NAME": "",
            "GITHUB_REF": "",
        },
        output_path=output_path,
    )

    assert exit_code == 0, (
        f"Expected exit 0 for empty diff with no PR context (local-invocation "
        f"preservation); got exit_code={exit_code}, stderr={stderr!r}"
    )
    # No 9788 / "empty diff" warning should be emitted in this case.
    assert "9788" not in stderr, (
        f"Did not expect bug-9788 warning for local invocation; got: {stderr!r}"
    )

    # findings.json should still be the historic empty-findings stub
    # (no skip_reason, since this is not a wiring-break condition).
    assert output_path.exists()
    data = json.loads(output_path.read_text(encoding="utf-8"))
    assert data == {"findings": []}, (
        f"Expected historic empty-findings dict for local invocation; got: {data}"
    )
